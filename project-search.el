;;; project-search.el --- Floating project file and Go symbol search -*- lexical-binding: t; -*-
;; One child-frame dialog: cheap local candidates appear at once, slower sources
;; (the `find' walk, gopls) are merged in as they answer.

(require 'tab-bar)
(require 'cl-lib)
(require 'subr-x)
(require 'recentf)
(require 'eglot)
(require 'treesit)
(require 'xref)

(declare-function my-references-popup "navigation" (fetcher alist))

;; Loading over an earlier version: close its dialog first, with that version's cleanup.
(when (fboundp 'my-search-close) (my-search-close))
(defconst my-search--file (or load-file-name buffer-file-name))

(defconst my-search-buffer-name " *Project search*")
(defvar-local my-search-rows 6 "Two-line results shown at once; fitted to the parent frame.")
(setq-default my-search-rows 6)
(defvar my-search-frame nil "Child frame of the open search dialog.")

(defvar-local my-search-kind nil "Either `file' or `symbol'.")
(defvar-local my-search-root nil "Project directory, with a trailing slash.")
(defvar-local my-search-roots nil "`my-search-root' and its true name, for server paths.")
(defvar-local my-search-tab-root nil "The tab's project root when opened; a change closes the dialog.")
(defvar-local my-search-origin nil "Editor window to navigate in and return to.")
(defvar-local my-search-active nil "Non-nil until the dialog's work is cleaned up.")
(defvar-local my-search-input nil "Marker at the start of the query.")
(defvar-local my-search-input-end nil "Marker at the end of the query, before the field's fill.")
(defvar-local my-search-rows-start nil "Position of the first result row.")
(defvar-local my-search-query "")
(defvar-local my-search-generation 0 "Bumped by query changes and closing; replies compare it.")
(defvar-local my-search-items nil "All candidates, newest first.")
(defvar-local my-search-seen nil "Keys of `my-search-items'.")
(defvar-local my-search-matches nil "Candidates matching the query, oldest first.")
(defvar-local my-search-matches-tail nil)
(defvar-local my-search-shown nil "`my-search-matches' in display order.")
(defvar-local my-search-selected nil "Key of the selected candidate.")
(defvar-local my-search-offset 0 "Index of the first visible row.")
(defvar-local my-search-loading nil "Non-nil while a slower source is still working.")
(defvar-local my-search-error nil)
(defvar-local my-search-timer nil)
(defvar-local my-search-cleanup nil "Functions that stop this dialog's work.")
(defvar-local my-search-server nil "Eglot server used for symbol search.")
(defvar-local my-search-request nil "(SERVER . ID) of the workspace/symbol request in flight.")
(defvar-local my-search-field-start 0 "First query character shown in the field.")
(defvar-local my-search-wheel-pixels 0 "Trackpad movement not yet turned into result steps.")
(defvar-local my-search-field-head nil "Overlay hiding query text before the shown part.")
(defvar-local my-search-field-tail nil "Overlay hiding query text after the shown part.")

;; Keymaps and faces are rebuilt on every load: `defvar' and `defface' would keep
;; an earlier version's bindings and attributes when this file is loaded again.
(defvar my-search-mode-map)
(setq my-search-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key (list [escape] (kbd "ESC") (kbd "C-g"))) (define-key map key #'my-search-close))
    (define-key map (kbd "RET") #'my-search-open-selected)
    (dolist (key (list [down] (kbd "C-n"))) (define-key map key #'my-search-next))
    (dolist (key (list [up] (kbd "C-p"))) (define-key map key #'my-search-previous))
    (define-key map (kbd "C-c C-r") #'my-search-references)
    (dolist (command '(delete-char delete-forward-char))
      (define-key map (vector 'remap command) #'my-search-delete-forward))
    (dolist (command '(delete-backward-char backward-delete-char-untabify))
      (define-key map (vector 'remap command) #'my-search-delete-backward))
    (define-key map [remap kill-line] #'my-search-kill-line)
    (define-key map [remap yank] #'my-search-yank)
    ;; Wheels and trackpads move through results instead of scrolling the dialog,
    ;; which would pull the field away until point snaps it back.
    (dolist (area '(nil header-line mode-line))
      (dolist (repeat '("" "double-" "triple-"))
        (dolist (base '(wheel-up wheel-down mouse-4 mouse-5))
          (define-key map (vconcat (and area (vector area)) (vector (intern (concat repeat (symbol-name base)))))
                      #'my-search-wheel))
        (dolist (base '(wheel-left wheel-right mouse-6 mouse-7))
          (define-key map (vconcat (and area (vector area)) (vector (intern (concat repeat (symbol-name base)))))
                      #'ignore))))
    map))

;; Colors only: the dialog inherits the editor's font family, size and weight.
(defconst my-search--faces
  '((my-search-field ((t :background "#898880" :foreground "#20211e"))
                     "Inside of the search field.")
    (my-search-border ((t :background "#4f4e49"))
                      "Thin outline of the search field; darker than the field and the dialog.")
    (my-search-dim ((t :foreground "#363830"))
                   "Kinds, paths, labels and status in the floating search dialog.")
    (my-search-name ((t :foreground "#20211e"))
                    "Result names in the floating search dialog.")
    (my-search-selected ((t :background "#1c4642" :foreground "#dbe5df" :extend t))
                        "Selected result; overrides the colors of names and paths, not the font.")))
(pcase-dolist (`(,face ,spec ,doc) my-search--faces)
  (custom-declare-face face spec doc :group 'faces)
  (face-spec-set face spec 'face-defface-spec))

;; Layout in canonical columns and lines, resolved at display time from the
;; inherited font, so a different editor font rescales the whole dialog.
(defconst my-search--inset 1.5 "Left and right content edge, in columns.")
(defconst my-search--column 9.0 "Where field and names start; labels and kinds sit before it.")
(defconst my-search--gap 0.5 "Space between blocks, in lines.")
(defconst my-search--pad 0.35 "Padding inside the field and around each result, in lines.")
(defconst my-search--thin '(:height 0.1) "Face of rows whose height comes only from a stretch.")

(defun my-search--space (face &rest spec)
  (propertize " " 'display (cons 'space spec) 'face face))

(defun my-search--spacer (height &optional face)
  "A blank row HEIGHT lines tall, drawn in FACE."
  (concat (my-search--space face :width '(1) :height height)
          (propertize "\n" 'face (list face my-search--thin))))

(defun my-search--field-row (height &optional fill)
  "A field row HEIGHT lines tall (nil: one text line) whose inside is FILL."
  (let ((height (and height (list :height height))))
    (concat (apply #'my-search--space nil :align-to my-search--column height)
            (apply #'my-search--space 'my-search-border :width '(1) height)
            (or fill (apply #'my-search--space 'my-search-field
                            :align-to `(- right ,my-search--inset (1)) height))
            (apply #'my-search--space 'my-search-border :width '(1) height)
            (propertize "\n" 'face (and height my-search--thin)))))

(defun my-search--edge-row ()
  "Top or bottom outline of the field."
  (concat (my-search--space nil :align-to my-search--column :height '(1))
          (my-search--space 'my-search-border :align-to `(- right ,my-search--inset) :height '(1))
          (propertize "\n" 'face my-search--thin)))

(defun my-search-delete-forward (n)
  "Delete N characters after point, within the query."
  (interactive "p")
  (delete-region (point) (min my-search-input-end (+ (point) n))))

(defun my-search-delete-backward (n)
  "Delete N characters before point, within the query."
  (interactive "p")
  (delete-region (max my-search-input (- (point) n)) (point)))

(defun my-search-kill-line ()
  "Kill the rest of the query."
  (interactive)
  (kill-region (point) my-search-input-end))

(defun my-search-yank ()
  "Insert the latest kill as one line of query text."
  (interactive)
  (insert (replace-regexp-in-string "[\n\r\t]+" " " (current-kill 0))))

(defun my-search--keep-point ()
  "Keep point, and so the caret, inside the query."
  (when (markerp my-search-input-end)
    (goto-char (max my-search-input (min (point) my-search-input-end)))
    (my-search--scroll-field)))

(defun my-search--field-room (window)
  "Columns of query text that fit in the field of WINDOW, one kept for the caret."
  (let ((cw (frame-char-width (window-frame window))))
    (max 4 (floor (- (window-body-width window t) 2
                     (* cw (+ my-search--column 0.6 my-search--inset 1)))
                  cw))))

(defun my-search--scroll-field ()
  "Show the part of the query around the caret inside the field.
The rest is folded into ellipses, so the line never outgrows the window and
nothing else in the dialog scrolls.  Matching still reads the whole query."
  (when-let* ((window (get-buffer-window (current-buffer) t))
              ((overlayp my-search-field-head)))
    (let* ((query (my-search--read-query)) (length (length query))
           (caret (- (point) my-search-input)) (room (my-search--field-room window))
           (start (max 0 (min my-search-field-start caret length)))
           (fits (lambda (from to)
                   (<= (+ (string-width query from to) (if (> from 0) 1 0) (if (< to length) 1 0))
                       room)))
           end)
      (if (<= (string-width query) room)
          (setq start 0 end length)
        (while (not (funcall fits start caret)) (cl-incf start))
        (setq end caret)
        (while (and (< end length) (funcall fits start (1+ end))) (cl-incf end))
        ;; At the end of the query, use the room on the left too.
        (while (and (= end length) (> start 0) (funcall fits (1- start) end)) (cl-decf start)))
      (setq my-search-field-start start)
      (move-overlay my-search-field-head my-search-input (+ my-search-input start))
      (overlay-put my-search-field-head 'display (and (> start 0) (propertize "…" 'face '(my-search-dim my-search-field))))
      (move-overlay my-search-field-tail (+ my-search-input end) my-search-input-end)
      (overlay-put my-search-field-tail 'display (and (< end length) (propertize "…" 'face '(my-search-dim my-search-field))))
      (set-window-hscroll window 0))))

(defvar my-search-row-map)
(setq my-search-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'my-search-click)
    map))

(define-derived-mode my-search-mode nil "Search"
  (setq-local truncate-lines t cursor-type 'bar tab-line-format nil buffer-undo-list t)
  (add-hook 'after-change-functions #'my-search--changed nil t)
  (add-hook 'post-command-hook #'my-search--keep-point nil t)
  ;; `pixel-scroll-precision-mode' binds the wheel in a minor-mode map, which
  ;; would outrank the dialog's own bindings.
  (setq-local minor-mode-overriding-map-alist
              (list (cons 'pixel-scroll-precision-mode my-search-mode-map)))
  (add-hook 'kill-buffer-hook #'my-search--stop nil t))

;;; Shared dialog

(defun my-search--context ()
  "Return (TAB-ROOT ROOT . EDITOR-WINDOW) for the selected tab."
  (let ((tab-root (alist-get 'my-project-root (tab-bar--current-tab))))
    (cons tab-root
          (cons (file-name-as-directory (expand-file-name (or tab-root default-directory)))
                (if (window-parameter (selected-window) 'window-side)
                    (or (seq-find (lambda (w) (not (window-dedicated-p w))) (window-list))
                        (selected-window))
                  (selected-window))))))

(defun my-search--live-p (buffer)
  "Non-nil if BUFFER's dialog is open and its project is still the tab's."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and my-search-active
              (or (and (window-live-p my-search-origin)
                       (equal my-search-tab-root
                              (with-selected-frame (window-frame my-search-origin)
                                (alist-get 'my-project-root (tab-bar--current-tab)))))
                  ;; The tab moved to another project or worktree: drop this dialog only.
                  (progn (run-at-time 0 nil #'my-search--close buffer t) nil))))))

(defun my-search--stop ()
  "Cancel this dialog's timers, processes and requests; idempotent."
  (setq my-search-active nil)
  (cl-incf my-search-generation)
  (when (timerp my-search-timer) (cancel-timer my-search-timer))
  (setq my-search-timer nil)
  (mapc #'funcall my-search-cleanup)
  (setq my-search-cleanup nil))

(defun my-search--close (buffer &optional invalid)
  "Close BUFFER's dialog.
INVALID means its project is gone, so the origin is not reselected."
  (when (buffer-live-p buffer)
    (let ((origin (buffer-local-value 'my-search-origin buffer))
          (window (get-buffer-window buffer t)))
      (with-current-buffer buffer (my-search--stop))
      (if (and (frame-live-p my-search-frame)
               (eq (window-buffer (frame-root-window my-search-frame)) buffer))
          (progn (delete-frame my-search-frame) (setq my-search-frame nil))
        (when (and (window-live-p window) (not (eq window origin)))
          (ignore-errors (delete-window window))))
      (kill-buffer buffer)
      (when (window-live-p origin)
        (select-frame-set-input-focus (window-frame origin))
        (unless invalid (select-window origin))))))

(defun my-search-close ()
  "Close the search dialog and return to the editor without navigating."
  (interactive)
  (when-let* ((buffer (get-buffer my-search-buffer-name))) (my-search--close buffer)))

(defun my-search--open (kind title footer)
  "Open an empty KIND dialog for the selected tab and return its buffer."
  (my-search-close)
  (pcase-let* ((`(,tab-root ,root . ,origin) (my-search--context))
               (buffer (get-buffer-create my-search-buffer-name)))
    (with-current-buffer buffer
      (my-search-mode)
      (setq my-search-kind kind my-search-root root my-search-tab-root tab-root
            my-search-roots (delete-dups (list root (file-name-as-directory (file-truename root))))
            my-search-origin origin my-search-active t default-directory root
            my-search-seen (make-hash-table :test #'equal)
            header-line-format
            (let ((project (file-name-nondirectory (directory-file-name root))))
              (list (my-search--space nil :align-to my-search--inset) title
                    (my-search--space nil :align-to `(- right ,my-search--inset ,(string-width project)))
                    (propertize (string-replace "%" "%%" project) 'face 'my-search-dim)))
            mode-line-format (list (my-search--space nil :align-to my-search--inset) footer))
      ;; Worktree switches only rewrite the tab's root, so poll even when idle.
      (let ((watch (run-with-timer 0.2 0.2 #'my-search--live-p buffer)))
        (push (lambda () (cancel-timer watch)) my-search-cleanup))
      (let ((inhibit-modification-hooks t) (inhibit-read-only t))
        ;; The query is real text between two glyphs: padding before it and a fill
        ;; after it, so the caret sits after the typed text, at the padding when empty.
        (insert (my-search--spacer my-search--gap) (my-search--edge-row)
                (my-search--field-row my-search--pad)
                (my-search--space nil :align-to my-search--inset)
                (propertize "Search" 'face 'my-search-dim)
                (my-search--space nil :align-to my-search--column)
                (my-search--space 'my-search-border :width '(1))
                (my-search--space 'my-search-field :width 0.6))
        (add-text-properties (point-min) (point) '(read-only t rear-nonsticky t))
        (setq my-search-input (point-marker))
        (insert (my-search--space 'my-search-field :align-to `(- right ,my-search--inset (1)))
                (my-search--space 'my-search-border :width '(1))
                (propertize "\n" 'read-only t))
        (setq my-search-input-end (copy-marker my-search-input t))
        (add-text-properties my-search-input-end (point) '(read-only t))
        ;; Typed text gets the field's background.
        (overlay-put (make-overlay my-search-input my-search-input-end nil nil t) 'face 'my-search-field)
        (setq my-search-field-head (make-overlay my-search-input my-search-input)
              my-search-field-tail (make-overlay my-search-input my-search-input))))
    (if (display-graphic-p (window-frame origin))
        (my-search--show-frame buffer (window-frame origin))
      (select-window (display-buffer buffer '((display-buffer-below-selected)
                                              (window-height . 20)))))
    (with-current-buffer buffer (goto-char my-search-input-end))
    buffer))

(defun my-search--show-frame (buffer parent)
  "Show BUFFER in a child frame over PARENT, styled like the other pickers."
  (setq my-search-frame
        (make-frame `((parent-frame . ,parent) (minibuffer . nil) (undecorated . t)
                      (visibility . nil) (no-accept-focus . nil) (no-other-frame . t)
                      (internal-border-width . 2) (drag-internal-border . t) (drag-with-header-line . t)
                      (tab-bar-lines . 0) (tab-bar-lines-keep-state . t) (menu-bar-lines . 0)
                      (tool-bar-lines . 0) (vertical-scroll-bars . nil)
                      (left-fringe . 0) (right-fringe . 0)
                      (background-color . "#999891") (foreground-color . "#20211e"))))
  (set-window-buffer (frame-root-window my-search-frame) buffer)
  (set-window-dedicated-p (frame-root-window my-search-frame) t)
  ;; Same font as the editor it floats over, whatever that is.
  (dolist (attribute '(:family :foundry :height :weight :slant :width))
    (set-face-attribute 'default my-search-frame attribute (face-attribute 'default attribute parent)))
  (let ((bar (max 2 (round (* my-search--gap (frame-char-height my-search-frame))))))
    (dolist (face '(header-line header-line-active header-line-inactive
                    mode-line mode-line-active mode-line-inactive))
      ;; Bar padding only; these faces keep the editor's font.
      (set-face-attribute face my-search-frame :background "#898880" :foreground "#20211e"
                          :box `(:line-width (1 . ,bar) :color "#898880"))))
  (set-face-attribute 'internal-border my-search-frame :background "#73726b")
  (my-search--fit my-search-frame)
  (add-hook 'window-size-change-functions #'my-search--parent-resized)
  (with-current-buffer buffer
    (push (lambda () (remove-hook 'window-size-change-functions #'my-search--parent-resized))
          my-search-cleanup))
  (make-frame-visible my-search-frame)
  (redisplay t)
  (my-search--fit my-search-frame)
  (select-frame-set-input-focus my-search-frame)
  (select-window (frame-root-window my-search-frame)))

(defun my-search--fit (frame)
  "Size FRAME for at most six whole two-line rows, inside its parent."
  (let* ((parent (frame-parent frame)) (window (frame-root-window frame))
         (buffer (window-buffer window)) (frame-resize-pixelwise t)
         (border (- (frame-pixel-height frame) (frame-text-height frame)))
         ;; Computed once: a visible frame's new size is applied asynchronously.
         (side (- (frame-pixel-width frame) (frame-text-width frame)))
         (width (max 200 (- (min 720 (- (frame-pixel-width parent) 16)) side)))
         (height (frame-text-height frame)))
    (set-frame-size frame width (frame-text-height frame) t)
    (with-current-buffer buffer
      (setq my-search-rows 6)
      (my-search--render)
      (let* ((inhibit-read-only t) (inhibit-modification-hooks t)
             (top (cdr (window-text-pixel-size window (point-min) my-search-rows-start)))
             (sample (save-excursion
                       ;; Measure a real row as rendered, then remove it.
                       (goto-char (point-max))
                       (let ((start (point)))
                         (insert (my-search--row '(:name "Name" :kind "func" :rel "a.go" :line 1 :match "a.go") 80 t))
                         (prog1 (cdr (window-text-pixel-size window start (point)))
                           (delete-region start (point))))))
             (chrome (+ (window-header-line-height window) (window-mode-line-height window)))
             (room (- (frame-pixel-height parent) 16 border chrome top)))
        (setq my-search-rows (max 1 (min 6 (/ room sample))))
        (my-search--render)
        (setq height (+ chrome top (* my-search-rows sample)))
        ;; Bars measure exactly only once drawn, so `my-search--show-frame' fits again then.
        (set-frame-size frame width height t)))
    (set-frame-position frame
                        (max 4 (/ (- (frame-pixel-width parent) width side) 2))
                        (max 4 (min (/ (frame-pixel-height parent) 8)
                                    (- (frame-pixel-height parent) height border 4))))))

(defun my-search--parent-resized (frame)
  (when (frame-live-p my-search-frame)
    (cond ((eq frame (frame-parent my-search-frame)) (my-search--fit my-search-frame))
          ((eq frame my-search-frame)
           (with-current-buffer (window-buffer (frame-root-window frame)) (my-search--scroll-field))))))

(defun my-search--read-query ()
  (buffer-substring-no-properties my-search-input my-search-input-end))

(defun my-search--changed (&rest _)
  (unless (equal (my-search--read-query) my-search-query) (my-search--schedule (current-buffer))))

(defun my-search--schedule (buffer)
  "Coalesce typing and arriving results into one refresh of BUFFER."
  (with-current-buffer buffer
    (unless (timerp my-search-timer)
      (setq my-search-timer (run-with-timer 0.05 nil #'my-search--flush buffer)))))

(defun my-search--flush (buffer)
  (when (my-search--live-p buffer)
    (with-current-buffer buffer
      (setq my-search-timer nil)
      (my-search--sync)
      (my-search--render))))

(defun my-search--sync ()
  "Apply the typed query now if refresh has not; gopls stays asynchronous.
Return non-nil if the query changed."
  (let ((query (my-search--read-query)))
    (unless (equal query my-search-query)
      (setq my-search-query query my-search-wheel-pixels 0)
      ;; Replies to the previous query compare this and are dropped.
      (cl-incf my-search-generation)
      (my-search--refilter)
      (when (eq my-search-kind 'symbol) (my-search--symbols-query query))
      t)))

(defun my-search--current-item ()
  "The selected result for the input as typed, or nil while none matches yet."
  (let ((buffer (current-buffer)))
    (unless (my-search--live-p buffer)
      (my-search--close buffer t)
      (user-error "The project changed; search closed"))
    (when (my-search--sync) (my-search--render))
    (when-let* ((item (my-search--selected-item))) (and (my-search--match-p item) item))))

(defun my-search--match-p (item)
  (let ((query my-search-query) (case-fold-search t))
    (if (string-empty-p query)
        (plist-get item :fast)
      (let ((re (regexp-quote query)))
        (or (string-match-p re (plist-get item :match))
            (equal (plist-get item :server-query) query)
            ;; A path pasted from outside the project root still matches its suffix.
            (and (eq my-search-kind 'file) (string-search "/" query)
                 (string-match-p re (plist-get item :file))))))))

(defun my-search--set-matches (matches)
  (setq my-search-matches matches my-search-matches-tail (last matches)))

(defun my-search--refilter ()
  (let (matches)
    (dolist (item my-search-items) (when (my-search--match-p item) (push item matches)))
    (my-search--set-matches matches)))

(defun my-search--add (buffer items)
  "Add unseen ITEMS to BUFFER's dialog and schedule a refresh."
  (with-current-buffer buffer
    (let (new)
      (dolist (item items)
        (let ((key (plist-get item :key)))
          (unless (gethash key my-search-seen)
            (puthash key t my-search-seen)
            (push item my-search-items)
            (when (my-search--match-p item) (push item new)))))
      (when new
        (setq new (nreverse new))
        (if my-search-matches (setcdr my-search-matches-tail new) (setq my-search-matches new))
        (setq my-search-matches-tail (last new))))
    (my-search--schedule buffer)))

(defun my-search--order ()
  (if (and (eq my-search-kind 'file) (length< my-search-matches 3000))
      ;; shortcut: larger match sets keep arrival order; typing more narrows them.
      (sort (copy-sequence my-search-matches)
            (lambda (a b) (let ((fa (plist-get a :fast)) (fb (plist-get b :fast)))
                            (if (eq (not fa) (not fb))
                                (< (length (plist-get a :match)) (length (plist-get b :match)))
                              fa))))
    my-search-matches))

(defun my-search--clip (text width)
  "TEXT shortened from the left to WIDTH columns."
  (if (<= (string-width text) width) text
    (concat "…" (truncate-string-to-width text (string-width text) (- (string-width text) (max 1 (1- width)))))))

(defconst my-search--kinds
  '(("function" . "func") ("variable" . "var") ("constant" . "const") ("interface" . "iface")
    ("property" . "prop") ("constructor" . "ctor") ("namespace" . "ns") ("package" . "pkg")
    ("enum member" . "member") ("type param" . "tparam"))
  "Short kinds that fit the column before names.")

(defun my-search--row (item width selected)
  "ITEM as a padded block: kind and name, then its location, within WIDTH columns."
  (let* ((file (eq my-search-kind 'file))
         (path (if file (plist-get item :match)
                 (format "%s:%d" (plist-get item :rel) (plist-get item :line))))
         (kind (if file (or (file-name-extension (plist-get item :match)) "file") (plist-get item :kind)))
         (kind (or (cdr (assoc kind my-search--kinds)) kind))
         (room (max 8 (floor (- width my-search--column my-search--inset))))
         (face (and selected 'my-search-selected))
         (row (concat (my-search--spacer my-search--pad face)
                      (my-search--space nil :align-to my-search--inset)
                      (propertize (truncate-string-to-width kind (floor (- my-search--column my-search--inset 1)))
                                  'face 'my-search-dim)
                      (my-search--space nil :align-to my-search--column)
                      (propertize (truncate-string-to-width (plist-get item :name) room nil nil "…")
                                  'face 'my-search-name)
                      "\n"
                      (my-search--space nil :align-to my-search--column)
                      ;; Paths lose their start first so the file name stays visible.
                      (propertize (my-search--clip path room) 'face 'my-search-dim)
                      "\n"
                      (my-search--spacer my-search--pad face))))
    (when selected (add-face-text-property 0 (length row) 'my-search-selected nil row))
    row))

(defun my-search--status ()
  (let ((count (length my-search-shown)) (files (eq my-search-kind 'file)))
    (cond (my-search-error (propertize (concat "  " my-search-error) 'face '(error my-search-dim)))
          ((and files my-search-loading)
           (format " Indexing… %d files · %d matches" (hash-table-count my-search-seen) count))
          ((and files (string-empty-p my-search-query))
           (format " %s · type to search %d files" (if (> count 0) "Open and recent files" "No recent files")
                   (hash-table-count my-search-seen)))
          (my-search-loading (format " Searching gopls… · %d local results" count))
          ((and (not files) (not my-search-server))
           (propertize (format " Go language server is not connected · %d results from open Go files" count)
                       'face 'warning))
          ((and (not files) (string-empty-p my-search-query))
           (format " Type to search workspace symbols · %d in open files" count))
          ((zerop count) (if files " No matching files" " No matching symbols"))
          (t (format " %d %s" count (if (= count 1) "result" "results"))))))

(defun my-search--render ()
  "Redraw the status and rows below the query, keeping the selection."
  (let* ((inhibit-read-only t) (inhibit-modification-hooks t)
         (window (get-buffer-window (current-buffer) t))
         (width (if window (window-max-chars-per-line window) 80))
         (start (save-excursion (goto-char my-search-input) (1+ (pos-eol))))
         (offset (- (point) my-search-input))
         (shown (setq my-search-shown (my-search--order)))
         (index (or (cl-position my-search-selected shown :key (lambda (it) (plist-get it :key)) :test #'equal) 0)))
    (setq my-search-selected (plist-get (nth index shown) :key)
          my-search-offset (max (min my-search-offset index) (- index my-search-rows -1)))
    (save-excursion
      (delete-region start (point-max))
      (goto-char start)
      (insert (my-search--field-row my-search--pad) (my-search--edge-row)
              (my-search--spacer my-search--gap)
              (my-search--space nil :align-to my-search--inset)
              (let ((status (string-trim-left (my-search--status))))
                (add-face-text-property 0 (length status) 'my-search-dim t status)
                (propertize status 'my-search-status t))
              "\n" (my-search--spacer (/ my-search--gap 2)))
      (setq my-search-rows-start (point))
      (cl-loop for item in (nthcdr my-search-offset shown) for i from my-search-offset
               repeat my-search-rows do
               (insert (propertize (my-search--row item width (= i index))
                                   'my-search-key (plist-get item :key) 'pointer 'hand
                                   'keymap my-search-row-map 'help-echo (plist-get item :file))))
      (add-text-properties start (point-max) '(read-only t)))
    ;; Results never move the caret out of, or within, the query.
    (goto-char (max my-search-input (min (+ my-search-input offset) my-search-input-end)))
    (my-search--scroll-field)))

(defun my-search-next (&optional n)
  "Select the Nth next result."
  (interactive "p")
  (when-let* ((shown my-search-shown))
    (let ((index (or (cl-position my-search-selected shown :key (lambda (it) (plist-get it :key)) :test #'equal) 0)))
      (setq my-search-selected (plist-get (nth (max 0 (min (1- (length shown)) (+ index (or n 1)))) shown) :key))
      (my-search--render))))

(defun my-search--selected-index ()
  (cl-position my-search-selected my-search-shown :key (lambda (it) (plist-get it :key)) :test #'equal))

(defun my-search--row-pixels ()
  "Displayed height of one result row, the trackpad distance of one step."
  (or (when-let* ((start my-search-rows-start)
                  ((get-text-property start 'my-search-key))
                  (window (get-buffer-window (current-buffer) t)))
        (cdr (window-text-pixel-size
              window start (next-single-property-change start 'my-search-key nil (point-max)))))
      (* 2 (frame-char-height))))

(defun my-search--wheel-pixels (dy)
  "Turn DY pixels of trackpad movement into result steps, keeping the remainder."
  (unless (zerop dy)
    ;; Leftover movement the other way would only delay the reversal.
    (when (< (* dy my-search-wheel-pixels) 0) (setq my-search-wheel-pixels 0))
    (let* ((total (+ my-search-wheel-pixels dy))
           (row (max 1 (my-search--row-pixels)))
           (steps (truncate total row)))
      (setq my-search-wheel-pixels (- total (* steps row)))
      (unless (zerop steps) (my-search-next steps))
      ;; Movement past either end cannot be used; drop it so reversing responds at once.
      (let ((index (my-search--selected-index)))
        (when (or (null index)
                  (and (> dy 0) (>= index (1- (length my-search-shown))))
                  (and (< dy 0) (<= index 0)))
          (setq my-search-wheel-pixels 0))))))

(defun my-search-wheel (event)
  "Move the selection by wheel or trackpad EVENT.
Pixel deltas accumulate into whole result rows; line-based wheels step by
their line count.  The dialog never scrolls; query, caret and field stay put."
  (interactive "e")
  (let* ((window (posn-window (event-start event)))
         (buffer (if (windowp window) (window-buffer window) (current-buffer)))
         (delta (nth 4 event)))
    (with-current-buffer buffer
      (when (derived-mode-p 'my-search-mode)
        (if (and (consp delta) (numberp (cdr delta)))
            ;; Native positive pixel deltas move toward the beginning.
            (my-search--wheel-pixels (- (cdr delta)))
          (setq my-search-wheel-pixels 0)
          (my-search-next (* (if (memq (event-basic-type event) '(wheel-up mouse-4)) -1 1)
                             (max 1 (event-line-count event)))))))))

(defun my-search-previous (&optional n)
  "Select the Nth previous result."
  (interactive "p")
  (my-search-next (- (or n 1))))

(defun my-search--selected-item ()
  (seq-find (lambda (it) (equal (plist-get it :key) my-search-selected)) my-search-shown))

(defun my-search--visit (item)
  "Close the dialog and show ITEM in the originating editor window."
  (let ((file (plist-get item :file)) (line (plist-get item :line)))
    (unless (and (stringp file) (file-regular-p file))
      (user-error "%s is no longer a file" (or file "The selection")))
    (my-search--close (current-buffer))
    (when line (xref-push-marker-stack))
    (find-file file)
    (when line
      (goto-char (point-min))
      (forward-line (1- line))
      (let ((col (or (plist-get item :col) 0)))
        ;; Server columns use the negotiated LSP encoding; local ones are characters.
        (if-let* ((move (plist-get item :lsp-move)))
            (funcall move col)
          (forward-char (min col (- (pos-eol) (point)))))))
    (current-buffer)))

(defun my-search-open-selected ()
  "Open the selected file or symbol definition."
  (interactive)
  (if-let* ((item (my-search--current-item)))
      (my-search--visit item)
    (message (if my-search-loading "Still searching…" "No result selected"))))

(defun my-search-click (event)
  "Open the result clicked by EVENT."
  (interactive "e")
  (let ((pos (posn-point (event-start event))))
    (with-current-buffer (window-buffer (posn-window (event-start event)))
      (when-let* ((key (and pos (get-text-property pos 'my-search-key))))
        (setq my-search-selected key)
        (my-search-open-selected)))))

;;; Files

(defun my-project-search-source (root)
  "Return (BASE PROGRAM . ARGS) for listing files below ROOT."
  (let ((copies (directory-file-name (expand-file-name "worktree" user-emacs-directory))))
    (cons root (append (list find-program "-H" (file-local-name root))
                       ;; Generated working copies of other projects are not part of this one.
                       (when (file-in-directory-p copies root)
                         (list "-path" (file-local-name copies) "-prune" "-o"))
                       (list "-type" "d" "-name" ".git" "-prune" "-o" "-type" "f" "-print0")))))

(defun my-search--file-item (root path &optional fast)
  "Candidate for PATH, a local name below ROOT as printed by `find'."
  (let ((rel (string-trim-left (substring path (min (length path) (length (file-local-name root)))) "/+")))
    (list :key rel :file (concat root rel) :match rel :name (file-name-nondirectory rel) :fast fast)))

(defun my-search--recent-files (root)
  "Open and recent files below ROOT that enumeration would also list."
  (let ((copies (file-name-as-directory (expand-file-name "worktree" user-emacs-directory))))
    (delq nil
          (mapcar (lambda (file)
                    (when (and file (string-prefix-p root file)
                               (not (and (not (string-prefix-p copies root)) (string-prefix-p copies file)))
                               (not (string-match-p "\\(?:\\`\\|/\\)\\.git/" (substring file (length root))))
                               (file-regular-p file))
                      (my-search--file-item root (file-local-name file) t)))
                  (delete-dups (append (delq nil (mapcar #'buffer-file-name (buffer-list)))
                                       (bound-and-true-p recentf-list)))))))

(defun my-search--files-start (buffer)
  "Offer recent files in BUFFER's dialog, then stream a fresh `find' listing."
  (with-current-buffer buffer
    (let* ((root my-search-root) (source (my-project-search-source root))
           (default-directory (car source))
           (errors (generate-new-buffer " *project-files-errors*"))
           (pending "") process)
      (my-search--add buffer (my-search--recent-files root))
      (setq my-search-loading t
            process
            (make-process
             :name "project-files" :buffer nil :stderr errors
             :command (cdr source) :connection-type 'pipe :noquery t :file-handler t
             :filter
             (lambda (_proc chunk)
               ;; Arc directory walks can be slow; offer complete paths as they arrive.
               (when (my-search--live-p buffer)
                 (setq pending (concat pending chunk))
                 (when-let* ((end (cl-position 0 pending :from-end t)))
                   (let ((paths (split-string (substring pending 0 end) "\0" t)))
                     (setq pending (substring pending (1+ end)))
                     (my-search--add buffer (mapcar (lambda (p) (my-search--file-item root p)) paths))))))
             :sentinel
             (lambda (proc _event)
               (when (and (memq (process-status proc) '(exit signal)) (my-search--live-p buffer))
                 (with-current-buffer buffer
                   (setq my-search-loading nil)
                   (unless (zerop (process-exit-status proc))
                     (setq my-search-error
                           (format "File indexing failed (exit %s): %s" (process-exit-status proc)
                                   (with-current-buffer errors (string-trim (buffer-string)))))))
                 (my-search--schedule buffer)))))
      (push (lambda ()
              (when (process-live-p process) (delete-process process))
              (when (buffer-live-p errors) (kill-buffer errors)))
            my-search-cleanup))))

(defun my-project-find-file ()
  "Find a file under the tab's folder or current directory using a fresh list."
  (interactive)
  (my-search-close)
  (let ((buffer (my-search--open 'file "Find file" "↑ ↓ Select · Enter Open · Esc Close")))
    (my-search--files-start buffer)
    (with-current-buffer buffer (my-search--render))
    buffer))

;;; Go symbols

(defconst my-search--lsp-kinds
  ["symbol" "file" "module" "namespace" "package" "type" "method" "property" "field"
   "constructor" "enum" "interface" "function" "variable" "constant" "string" "number"
   "boolean" "array" "object" "key" "null" "enum member" "type" "event" "operator" "type param"])

(defconst my-search--go-query
  '((function_declaration name: (identifier) @function)
    (method_declaration name: (field_identifier) @method)
    (type_spec name: (type_identifier) @type)
    (type_alias name: (type_identifier) @type)
    (const_spec (identifier) @constant)
    (var_spec (identifier) @variable)))

(defun my-search--rel (file)
  "FILE relative to the project, or nil when outside it."
  (cl-some (lambda (root) (and (string-prefix-p root file) (substring file (length root))))
           my-search-roots))

(defun my-search--symbol-key (file line name)
  (list (file-truename file) line name))

(defun my-search--go-buffer-symbols (buffer root)
  "Top-level declarations of Go BUFFER below ROOT, from its syntax tree."
  (with-current-buffer buffer
    (when (and buffer-file-name (derived-mode-p 'go-ts-mode) (string-prefix-p root buffer-file-name)
               (treesit-parser-list nil 'go))
      (let ((file buffer-file-name) (rel (substring buffer-file-name (length root))) items)
        (pcase-dolist (`(,kind . ,node) (treesit-query-capture 'go my-search--go-query))
          (unless (treesit-parent-until node (lambda (n) (member (treesit-node-type n) '("block" "field_declaration_list"))))
            (let* ((pos (treesit-node-start node))
                   (line (line-number-at-pos pos t))
                   (recv (and (eq kind 'method)
                              (treesit-node-text (treesit-node-child-by-field-name (treesit-node-parent node) "receiver") t)))
                   (name (concat (and recv (string-match "\\([[:alnum:]_]+\\)\\(?:\\[[^]]*\\]\\)?[[:space:]]*)\\'" recv)
                                      (concat (match-string 1 recv) "."))
                                 (treesit-node-text node t))))
              (push (list :key (my-search--symbol-key file line name) :file file :rel rel :line line
                          :col (save-excursion (goto-char pos) (- pos (pos-bol)))
                          :name name :kind (symbol-name kind) :match name :fast t :server-query nil)
                    items))))
        (nreverse items)))))

(defun my-search--go-server (origin root)
  "A live Eglot server of a Go buffer below ROOT, preferring ORIGIN's."
  (cl-some (lambda (buffer)
             (with-current-buffer buffer
               (when-let* (((and buffer-file-name (derived-mode-p 'go-ts-mode 'go-mode)
                                 (string-prefix-p root buffer-file-name)))
                           (server (eglot-current-server)))
                 (and (jsonrpc-running-p server) server))))
           (cons (window-buffer origin) (buffer-list))))

(defun my-search--symbols-cancel ()
  (when-let* ((request my-search-request))
    (when (jsonrpc-running-p (car request))
      (jsonrpc-notify (car request) '$/cancelRequest (list :id (cdr request))))
    (setq my-search-request nil)))

(defun my-search--symbols-query (query)
  "Ask gopls for QUERY's workspace symbols; earlier requests are cancelled."
  (my-search--symbols-cancel)
  (setq my-search-loading nil my-search-error nil)
  (when (and my-search-server (not (string-empty-p query)))
    (if (not (jsonrpc-running-p my-search-server))
        (setq my-search-server nil)
      (let ((buffer (current-buffer)) (generation my-search-generation))
        (setq my-search-loading t
              my-search-request
              (cons my-search-server
                    (car (jsonrpc-async-request
                          my-search-server :workspace/symbol (list :query query)
                          :success-fn (lambda (result) (my-search--symbols-arrive buffer generation query result nil))
                          :error-fn (lambda (err) (my-search--symbols-arrive
                                                   buffer generation query nil
                                                   (or (plist-get err :message) "request failed")))
                          :timeout-fn (lambda () (my-search--symbols-arrive buffer generation query nil "timed out"))))))))))

(defun my-search--symbols-arrive (buffer generation query result failure)
  "Merge gopls RESULT for QUERY unless BUFFER's dialog moved on."
  (when (and (my-search--live-p buffer) (= generation (buffer-local-value 'my-search-generation buffer)))
    (with-current-buffer buffer
      (setq my-search-loading nil my-search-request nil
            my-search-error (and failure (format "Go language server: %s" failure)))
      (unless failure
        ;; Replace answers to earlier queries; symbols from open files stay.
        (setq my-search-items (cl-remove-if (lambda (it) (when (plist-get it :server) (remhash (plist-get it :key) my-search-seen) t))
                                            my-search-items))
        (let ((move (pcase (ignore-errors (plist-get (eglot--capabilities my-search-server) :positionEncoding))
                      ("utf-32" #'eglot-move-to-utf-32-linepos)
                      ("utf-8" #'eglot-move-to-utf-8-linepos)
                      (_ #'eglot-move-to-utf-16-linepos)))
              new)
          (seq-doseq (info result)
            (let* ((location (plist-get info :location))
                   (file (eglot-uri-to-path (plist-get location :uri)))
                   (start (plist-get (plist-get location :range) :start))
                   (rel (and start (my-search--rel file))))
              (when rel
                (let* ((line (1+ (plist-get start :line))) (name (plist-get info :name))
                       (key (my-search--symbol-key file line name)))
                  (if-let* ((local (seq-find (lambda (it) (equal (plist-get it :key) key)) my-search-items)))
                      (plist-put local :server-query query)
                    (push (list :key key :file file :rel rel :line line :col (plist-get start :character) :lsp-move move
                                :name name :match name :server t :server-query query
                                :kind (aref my-search--lsp-kinds (min (or (plist-get info :kind) 0)
                                                                      (1- (length my-search--lsp-kinds)))))
                          new))))))
          (my-search--refilter)
          (my-search--add buffer (nreverse new))))
      (my-search--schedule buffer))))

(defun my-project-find-symbol ()
  "Search Go symbols of the tab's project: open files at once, then gopls."
  (interactive)
  (my-search-close)
  (let ((buffer (my-search--open 'symbol "Go symbols"
                                 "↑ ↓ Select · Enter Open · C-c C-r References · Esc Close")))
    (with-current-buffer buffer
      (let ((origin my-search-origin) (root my-search-root))
        (setq my-search-server (my-search--go-server origin root))
        (push #'my-search--symbols-cancel my-search-cleanup)
        (my-search--add buffer (seq-mapcat (lambda (b) (my-search--go-buffer-symbols b root))
                                           (delete-dups (cons (window-buffer origin) (buffer-list)))))
        (my-search--render)))
    buffer))

(defun my-search-references ()
  "Open the selected symbol's definition and list its references."
  (interactive)
  (unless (eq my-search-kind 'symbol) (user-error "References are available for symbols"))
  (let* ((item (or (my-search--current-item)
                   (user-error (if my-search-loading "Still searching…" "No symbol selected"))))
         (buffer (my-search--visit item)) (point (point)))
    ;; Eglot attaches a newly visited file after this command finishes.
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (if (not (eglot-managed-p))
                           (message "Go language server is not connected for %s" (buffer-name))
                         (save-excursion
                           (goto-char point)
                           (let ((xref-show-xrefs-function #'my-references-popup)
                                 (xref-auto-jump-to-first-xref nil))
                             (xref-find-references (xref-backend-identifier-at-point 'eglot)))))))))))

(global-set-key (kbd "C-c p o") #'my-project-find-file)
(global-set-key (kbd "C-c p s") #'my-project-find-symbol)

(defun my-search-reload ()
  "Close search and load this file again, replacing its faces and key bindings."
  (interactive)
  (my-search-close)
  (load my-search--file nil t))
(provide 'my-project-search)
;;; project-search.el ends here
