;;; disk-changes.el --- Review external file changes before reloading -*- lexical-binding: t; -*-

;; A changed file is never reloaded silently: its buffer gets a header-line
;; notification, and the user chooses to compare,
;; reload or keep the editor version.

(require 'cl-lib)
(require 'autorevert)
(require 'ediff)
(require 'svg)

(defvar my-disk-recovery-directory (locate-user-emacs-file "disk-conflicts/")
  "Where unsaved editor text is copied before reloading from disk.")

(defvar-local my-disk-baseline nil "Hash of the disk version the unsaved edits started from.")
(defvar-local my-disk-ack nil "Hash of a disk version the user chose to keep the editor over.")
(defvar-local my-disk-pending nil "Unresolved change: plist with :hash, :expanded and :again.")
(defvar-local my-disk-saved-header nil "(LOCALP . VALUE) of the header line replaced by a notification.")
(defvar-local my-disk-compare nil "Live comparison: plist with :control and :hash.")
(defvar-local my-disk-seen nil "Modification time and size of the disk version last examined.")
(defvar-local my-disk-source nil "Editor buffer a comparison snapshot was taken from.")
(defvar-local my-disk-snapshot-label nil)
(defvar-local my-disk-snapshot-hash nil)
(dolist (var '(my-disk-baseline my-disk-ack my-disk-pending my-disk-saved-header my-disk-compare my-disk-seen))
  (put var 'permanent-local t))
(defvar my-disk-timer nil)
(defvar revert-buffer-preserve-modes) ; bound by `revert-buffer' for `after-revert-hook' users

(defun my-disk-covered-p ()
  "Return non-nil for a local, plain file buffer that this workflow guards."
  (and buffer-file-name
       (not (string-prefix-p " " (buffer-name)))
       (not (file-remote-p buffer-file-name))
       ;; Compressed and archive files do not compare byte for byte.
       (not (find-file-name-handler buffer-file-name 'insert-file-contents-literally))
       (not (file-directory-p buffer-file-name))))

(defun my-disk-meta (file)
  "Return FILE's (MTIME SIZE), or nil when it does not exist."
  (when-let* ((attributes (file-attributes file)))
    (list (file-attribute-modification-time attributes) (file-attribute-size attributes))))

(defun my-disk-read ()
  "Return (HASH BYTES META) for one unchanging version of the visited file.
META is the (MTIME SIZE) of exactly those BYTES.  HASH is `missing' when
the file is unreadable, and nil when it kept changing during every read."
  (let ((file buffer-file-name) result)
    (dotimes (_ 3)
      (unless result
        (let* ((before (my-disk-meta file))
               (bytes (condition-case nil
                          (when (file-regular-p file)
                            (with-temp-buffer
                              (set-buffer-multibyte nil)
                              (insert-file-contents-literally file)
                              (buffer-string)))
                        (error nil)))
               (after (my-disk-meta file)))
          (when (equal before after)
            (setq result (list (if bytes (secure-hash 'sha1 bytes) 'missing) bytes after))))))
    (or result (list nil nil nil))))

(defun my-disk-editor-text ()
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))

(defun my-disk-same-as-editor-p (bytes)
  "Return non-nil when the editor text encodes to BYTES."
  (and bytes (equal bytes (encode-coding-string
                           (my-disk-editor-text)
                           (or buffer-file-coding-system 'utf-8-unix)))))

(defun my-disk-name () (file-name-nondirectory buffer-file-name))

;;; Detection

(defun my-disk-check (&optional buffer)
  "Notify about an unreviewed external change to BUFFER's file."
  (with-current-buffer (or buffer (current-buffer))
    (when (my-disk-covered-p)
      (if (verify-visited-file-modtime)
          (when my-disk-pending (my-disk-resolve))
        (let ((seen (my-disk-meta buffer-file-name)))
          ;; Same metadata as the version already examined: nothing new to read.
          (unless (and seen (equal seen my-disk-seen))
            (pcase-let ((`(,hash ,bytes ,meta) (my-disk-read)))
             ;; A file that kept changing while read stays unexamined for the next check.
             (when hash
              (setq my-disk-seen meta)
              (cond
               ((and my-disk-pending (equal hash (plist-get my-disk-pending :hash))))
               ((and bytes (or (equal hash my-disk-baseline)
                               (my-disk-same-as-editor-p bytes)))
                ;; Metadata-only change, or the disk already holds the editor text.
                ;; Only the time of the bytes just compared, never a newer write.
                (set-visited-file-modtime (car meta))
                (my-disk-resolve))
               ((equal hash my-disk-ack) (when my-disk-pending (my-disk-resolve)))
               (t (my-disk-notify hash)))))))))))

(defun my-disk-notify (hash)
  (setq my-disk-pending (list :hash hash :expanded t :again (and my-disk-pending t)))
  (my-disk-show-header)
  (force-mode-line-update t))

(defun my-disk-resolve ()
  (setq my-disk-pending nil)
  (my-disk-hide-header)
  (force-mode-line-update t))

(defun my-disk-check-visible ()
  "Check the file buffers shown in the selected frame."
  (setq my-disk-timer nil)
  (dolist (buffer (delete-dups (mapcar #'window-buffer (window-list nil 'nomini))))
    (with-demoted-errors "Disk change check: %S" (my-disk-check buffer))))

(defun my-disk-schedule (&rest _)
  "Coalesce navigation and focus events into one check after they settle."
  (unless (timerp my-disk-timer)
    (setq my-disk-timer (run-at-time 0.1 nil #'my-disk-check-visible))))

(defun my-disk-auto-revert (revert)
  "Notify instead of letting auto-revert reload a guarded buffer."
  (if (my-disk-covered-p)
      (progn (setq auto-revert-notify-modified-p nil)
             (with-demoted-errors "Disk change check: %S" (my-disk-check)))
    (funcall revert)))

(defun my-disk-record-baseline ()
  "Remember the disk version that the first unsaved edit starts from."
  (when (and (my-disk-covered-p) (verify-visited-file-modtime))
    (pcase-let ((`(,hash ,bytes ,meta) (my-disk-read)))
      ;; A write after the check above yields a newer snapshot: never adopt it.
      (when (and bytes (time-equal-p (car meta) (visited-file-modtime)))
        (setq my-disk-baseline hash)))))

(defun my-disk-reset ()
  "Forget conflict state once the buffer and file agree after save or revert."
  (setq my-disk-baseline nil my-disk-ack nil my-disk-seen nil)
  (when my-disk-pending (my-disk-resolve)))

;;; Notification

(defun my-disk-button (text help command)
  "Header or mode-line button TEXT that runs COMMAND in the clicked window."
  (let ((action (lambda (event)
                  (interactive "e")
                  (select-window (posn-window (event-start event)))
                  (call-interactively command)))
        (map (make-sparse-keymap)))
    (dolist (area '(header-line mode-line))
      (define-key map (vector area 'down-mouse-1) #'ignore)
      (define-key map (vector area 'mouse-1) action))
    (propertize text 'mouse-face 'mode-line-highlight 'help-echo help 'local-map map)))

(defconst my-disk-actions
  '((my-disk-compare "Compare" "Compare" "c" "Compare the editor and disk versions side by side")
    (my-disk-reload "Reload from Disk" "Reload" "r" "Replace the editor contents with the disk version")
    (my-disk-keep "Keep Editor Version" "Keep" "k" "Keep the editor contents; nothing is written to disk")
    (my-disk-later "Later" "Later" "l" "Hide this notice; reopen it with C-c d d"))
  "(COMMAND LABEL SHORT-LABEL KEY HELP) for each notification action.")

(defun my-disk-available-actions ()
  "Actions for the pending change; a missing file cannot be compared or reloaded."
  (if (eq (plist-get my-disk-pending :hash) 'missing)
      (seq-filter (lambda (action) (memq (car action) '(my-disk-keep my-disk-later))) my-disk-actions)
    my-disk-actions))

(defun my-disk-message ()
  "The full sentence describing the pending change."
  (let ((name (my-disk-name)) (new (if (plist-get my-disk-pending :again) "new " "")))
    (cond ((eq (plist-get my-disk-pending :hash) 'missing)
           (format "%s was deleted or cannot be read. The editor contents are kept." name))
          ((buffer-modified-p)
           (format "%s has %sexternal changes. Your editor has unsaved changes." name new))
          (t (format "%s has %sexternal changes." name new)))))

;; The theme's header and mode lines share the editor's gray, so the notice uses its own colors.
(defface my-disk-notice '((t :background "#303b40" :foreground "#f1f4f3"))
  "Bar of a disk change notification.")
(defface my-disk-notice-title '((t :background "#b1ded8" :foreground "#203334" :weight bold))
  "Title of a disk change notification.")
(defface my-disk-notice-status '((t :foreground "#b1ded8" :weight bold))
  "File status in a disk change notification.")
(defface my-disk-notice-button '((t :background "#b1ded8" :foreground "#203334"))
  "Action buttons of a disk change notification.")

(defun my-disk-action-buttons (short)
  (mapconcat (pcase-lambda (`(,command ,label ,short-label ,key ,help))
               (propertize (my-disk-button (format "[%s]" (if short short-label label))
                                           (format "%s: %s (C-c d %s)" label help key) command)
                           'my-disk-action command 'face 'my-disk-notice-button))
             (my-disk-available-actions) " "))

(defun my-disk-header-line (&optional width)
  "A one-line notice whose actions stay visible within WIDTH columns."
  (let* ((width (or width (window-width)))
         (missing (eq (plist-get my-disk-pending :hash) 'missing))
         (help (concat (my-disk-message) "\nAll actions: C-c d m"))
         (title (propertize (if missing " Missing on disk " " Changed on disk ")
                            'face 'my-disk-notice-title 'help-echo help))
         (state (cond (missing " (deleted)")
                      ((buffer-modified-p) " (unsaved edits)")
                      (t "")))
         (menu (propertize (my-disk-button "[Actions]" (concat help "\nmouse-1: choose an action")
                                           #'my-disk-choose)
                           'my-disk-action 'my-disk-choose 'face 'my-disk-notice-button))
         ;; Full labels, then short ones, then only the menu: never clip an action.
         (actions (seq-find (lambda (text) (<= (+ (string-width title) 9 (string-width state)
                                                   (string-width text) 3)
                                                width))
                            (list (my-disk-action-buttons nil) (my-disk-action-buttons t))
                            menu))
         ;; One column is the stretch that paints the rest of the bar.
         (room (- width (string-width title) (string-width actions) 4))
         (name (my-disk-name)))
    (when (< (- room (string-width state)) 6) (setq state ""))
    (let ((line (concat title " "
                        (propertize (truncate-string-to-width name (max 1 (- room (string-width state)))
                                                              nil nil "…")
                                    'help-echo help)
                        (propertize state 'face 'my-disk-notice-status 'help-echo help)
                        "  " actions
                        (propertize " " 'display '(space :align-to right)))))
      (add-face-text-property 0 (length line) 'my-disk-notice t line)
      line)))

(defvar-local my-disk-panel-cache nil)

(defun my-disk-panel-layout (width font)
  "Lay out the notice and clickable buttons inside WIDTH pixels at FONT size."
  (let* ((gap 12) (margin 20) (char-width (* font 0.65))
         (button-height (+ font 22)) (x margin) (y (+ (* font 3) 38))
         (missing (eq (plist-get my-disk-pending :hash) 'missing))
         (suffix (cond (missing " cannot be read. Editor contents are kept.")
                       ((buffer-modified-p) " changed on disk. Unsaved editor changes.")
                       (t " was updated outside Emacs. Review the changes.")))
         (columns (floor (/ (- width (* 2 margin)) char-width)))
         (suffix (if (< columns 55)
                     (cond (missing " — File unavailable")
                           ((buffer-modified-p) " — Unsaved changes")
                           (t " — Changed on disk"))
                   suffix))
         (name (truncate-string-to-width (my-disk-name)
                                         (max 1 (- columns (length suffix))) nil nil "…"))
         buttons)
    (pcase-dolist (`(,command ,label ,short ,_ ,_) (my-disk-available-actions))
      (when (> (+ (* (length label) char-width) 28) (- width (* 2 margin)))
        (setq label short))
      (let ((w (ceiling (+ (* (length label) char-width) 28))))
        (when (> (+ x w) (- width margin))
          (setq x margin y (+ y button-height gap)))
        (push (list command label x y w button-height) buttons)
        (setq x (+ x w gap))))
    (list :width width :height (+ y button-height margin) :font font
          :title (if missing "File missing on disk" "File changed on disk")
          :description (truncate-string-to-width (concat name suffix) columns nil nil "…")
          :buttons (nreverse buttons))))

(defun my-disk-panel-target (layout x y)
  "Return the command under image coordinates X,Y in LAYOUT."
  (car (seq-find (pcase-lambda (`(,_ ,_ ,left ,top ,width ,height))
                   (and (<= left x) (< x (+ left width)) (<= top y) (< y (+ top height))))
                 (plist-get layout :buttons))))

(defun my-disk-panel-click (event)
  (interactive "e")
  (let* ((posn (event-start event)) (string (posn-string posn))
         (xy (posn-object-x-y posn))
         (layout (and string (get-text-property (cdr string) 'my-disk-panel (car string)))))
    (when-let* ((command (and layout xy (my-disk-panel-target layout (car xy) (cdr xy)))))
      (select-window (posn-window posn))
      (call-interactively command))))

(defvar-keymap my-disk-panel-map
  "<header-line> <down-mouse-1>" #'ignore
  "<header-line> <mouse-1>" #'my-disk-panel-click)

(defun my-disk-panel-image (layout family)
  "Draw LAYOUT as a dark slate panel with padded action buttons."
  (let* ((font (plist-get layout :font))
         (svg (svg-create (plist-get layout :width) (plist-get layout :height)
                          :font-family family :font-size font)))
    (svg-rectangle svg 0 0 (plist-get layout :width) (plist-get layout :height) :fill "#303b40")
    (svg-text svg "↻" :x 20 :y (+ font 24) :font-size (+ font 12) :fill "#b1ded8")
    (svg-text svg (truncate-string-to-width
                   (plist-get layout :title)
                   (max 1 (floor (/ (- (plist-get layout :width) 76) (* (+ font 4) 0.65)))) nil nil "…")
              :x 56 :y (+ font 22)
              :font-size (+ font 4) :font-weight "bold" :fill "#f1f4f3")
    (svg-text svg (plist-get layout :description) :x 20 :y (+ (* font 2) 36) :fill "#c5cecf")
    (pcase-dolist (`(,command ,label ,x ,y ,w ,h) (plist-get layout :buttons))
      (let ((primary (eq command 'my-disk-compare)) (quiet (eq command 'my-disk-later)))
        (unless quiet
          (svg-rectangle svg x y w h :rx 5 :ry 5 :stroke-width 1
                         :stroke (if primary "#b1ded8" "#a4b2b5")
                         :fill (if primary "#b1ded8" "#303b40")))
        (svg-text svg label :x (+ x (/ w 2)) :y (+ y (/ h 2) (* font 0.35))
                  :text-anchor "middle" :font-weight (if primary "bold" "normal")
                  :fill (if primary "#203334" "#f1f4f3"))))
    (svg-image svg :ascent 'center :scale 1)))

(defun my-disk-header ()
  "Render the full panel in graphical Emacs, with a text fallback for terminals."
  (if (not (and (display-graphic-p) (image-type-available-p 'svg)))
      (my-disk-header-line)
    (let* ((width (max 100 (- (window-pixel-width) (frame-char-width))))
           (font (max 14 (round (* (frame-char-height) 0.8))))
           (family (face-attribute 'default :family nil t))
           (key (list width font family (my-disk-message))))
      (unless (equal key (car my-disk-panel-cache))
        (let ((layout (my-disk-panel-layout width font)))
          (setq my-disk-panel-cache
                (cons key (propertize " " 'display (my-disk-panel-image layout family)
                                      'my-disk-panel layout 'local-map my-disk-panel-map
                                      'help-echo (concat (my-disk-message) "\nActions: C-c d m")
                                      'pointer 'hand)))))
      (cdr my-disk-panel-cache))))

(defun my-disk-choose ()
  "Choose any action for the current buffer's disk change from a menu."
  (interactive)
  (unless my-disk-pending (user-error "%s has no unreviewed disk changes" (my-disk-name)))
  (popup-menu (cons (my-disk-message)
                    (mapcar (pcase-lambda (`(,command ,label ,_ ,key ,_))
                              (vector label command :keys (concat "C-c d " key)))
                            (my-disk-available-actions)))
              (if (mouse-event-p last-nonmenu-event) last-nonmenu-event (or (posn-at-point) t))))

(defun my-disk-show-header ()
  (unless my-disk-saved-header
    (setq my-disk-saved-header (cons (local-variable-p 'header-line-format) header-line-format)))
  (setq-local header-line-format '(:eval (my-disk-header))))

(defun my-disk-hide-header ()
  (when my-disk-saved-header
    (if (car my-disk-saved-header)
        (setq header-line-format (cdr my-disk-saved-header))
      (kill-local-variable 'header-line-format))
    (setq my-disk-saved-header nil)))

;;; Actions

(defun my-disk-reviewed ()
  "Return (HASH BYTES META) when the disk still holds the version under review.
Otherwise refresh the notification and any comparison, and return nil."
  (unless (my-disk-covered-p) (user-error "This buffer does not visit a local file"))
  ;; Taken before rechecking, so a write noticed now is never applied unseen.
  (let ((reviewed (if (buffer-live-p (plist-get my-disk-compare :control))
                      (plist-get my-disk-compare :hash)
                    (plist-get my-disk-pending :hash))))
    (my-disk-check)
    (unless my-disk-pending (user-error "%s has no unreviewed disk changes" (my-disk-name)))
    (let ((disk (my-disk-read)))
      (if (equal (car disk) reviewed)
          disk
        (when (buffer-live-p (plist-get my-disk-compare :control)) (my-disk-compare))
        (message "%s changed again on disk. Review the new version first." (my-disk-name))
        nil))))

(defun my-disk-save-recovery ()
  "Copy the editor text to a new file and return its name."
  (make-directory my-disk-recovery-directory t)
  (let ((file (make-temp-file (expand-file-name (concat (my-disk-name) ".")
                                                my-disk-recovery-directory)
                              nil (format-time-string ".%Y%m%d-%H%M%S")))
        (coding-system-for-write (or buffer-file-coding-system 'utf-8-unix)))
    (write-region nil nil file nil 'silent)
    file))

(defun my-disk-reload ()
  "Replace the editor contents with the reviewed disk version."
  (interactive)
  (when-let* ((disk (my-disk-reviewed)))
    (unless (cadr disk) (user-error "%s cannot be read from disk" (my-disk-name)))
    (when (and (buffer-modified-p)
               (not (y-or-n-p (format "Discard unsaved changes in %s and reload from disk? A recovery copy is saved first. "
                                      (my-disk-name)))))
      (user-error "Reload canceled"))
    ;; The prompt may have taken a while; another write must be reviewed first.
    (when-let* ((disk (my-disk-reviewed)))
      (let ((recovery (and (buffer-modified-p) (my-disk-save-recovery))))
        (if (not (equal (my-disk-meta buffer-file-name) (nth 2 disk)))
            ;; Written during the recovery copy: leave the editor as it is.
            (progn (my-disk-check)
                   (message "%s changed again on disk. Review the new version first.%s" (my-disk-name)
                            (if recovery (format " Unsaved changes were also copied to %s" recovery) "")))
          (my-disk-apply disk)
          (message (if recovery (format "Reloaded %s. Unsaved changes were copied to %s"
                                        (my-disk-name) recovery)
                     (format "Reloaded %s from disk." (my-disk-name)))))))))

(defun my-disk-apply (disk)
  "Replace the editor text with the verified bytes of DISK, as a revert would.
Nothing is read again, so an unseen write cannot slip in."
  (let ((windows (mapcar (lambda (window) (list window (window-start window) (window-point window)))
                         (get-buffer-window-list nil nil t)))
        (source (current-buffer))
        (text (decode-coding-string (cadr disk) (or buffer-file-coding-system 'utf-8-unix))))
    (let ((revert-buffer-in-progress t)
          (revert-buffer-preserve-modes t)
          (inhibit-read-only t))
      (run-hooks 'before-revert-hook)
      (save-restriction
        (widen)
        (with-temp-buffer
          (insert text)
          (let ((temp (current-buffer)))
            (with-current-buffer source
              ;; Without a truename, editing skips the lock's supersession prompt.
              (unless (let ((buffer-file-truename nil)) (replace-region-contents (point-min) (point-max) temp 1.0))
                ;; Fell back to a wholesale replacement: put windows back by position.
                (pcase-dolist (`(,window ,start ,point) windows)
                  (set-window-start window (min start (point-max)) t)
                  (set-window-point window (min point (point-max)))))))))
      ;; The version applied, so a later write is still detected and still guarded.
      (set-visited-file-modtime (car (nth 2 disk)))
      (set-buffer-modified-p nil)
      (run-hooks 'after-revert-hook))))

(defun my-disk-keep ()
  "Keep the editor contents and stop notifying about the reviewed disk version."
  (interactive)
  (when-let* ((disk (my-disk-reviewed)))
    (setq my-disk-ack (car disk))
    ;; The supersession check still asks before a later save overwrites the file.
    (unless (my-disk-same-as-editor-p (cadr disk))
      ;; Without a truename, marking skips the lock's own supersession prompt.
      (let ((buffer-file-truename nil)) (set-buffer-modified-p t)))
    (my-disk-resolve)
    (message "Kept the editor version of %s. Nothing was written to disk." (my-disk-name))))

(defun my-disk-later ()
  "Hide the notification; `my-disk-review' opens it again."
  (interactive)
  (when my-disk-pending
    (plist-put my-disk-pending :expanded nil)
    (my-disk-hide-header)))

(defun my-disk-review ()
  "Show the notification for the current buffer's disk change again."
  (interactive)
  (my-disk-check)
  (if (not my-disk-pending)
      (message "%s has no unreviewed disk changes." (my-disk-name))
    (plist-put my-disk-pending :expanded t)
    (my-disk-show-header)))

;;; Comparison

(defun my-disk-snapshot (label text mode source hash)
  "Return a read-only buffer named after LABEL holding TEXT in MODE."
  (with-current-buffer (generate-new-buffer
                        (format "*%s: %s*" label (with-current-buffer source (my-disk-name))))
    (insert text)
    ;; Mode hooks would start language servers for a buffer without a file.
    (condition-case nil (delay-mode-hooks (funcall mode)) (error (fundamental-mode)))
    (font-lock-mode 1)
    ;; Wrapped lines would take a different number of rows in each pane.
    (setq my-disk-source source my-disk-snapshot-label label my-disk-snapshot-hash hash
          buffer-read-only t truncate-lines t)
    (setq-local display-line-numbers-type t)
    (display-line-numbers-mode 1)
    (my-disk-snapshot-mode 1)
    (setq-local header-line-format '(:eval (my-disk-snapshot-header)))
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (current-buffer)))

(defun my-disk-snapshot-header ()
  (concat " " (propertize my-disk-snapshot-label 'face 'bold)
          (and my-disk-snapshot-hash (buffer-live-p my-disk-source)
               (not (equal my-disk-snapshot-hash
                           (plist-get (buffer-local-value 'my-disk-pending my-disk-source) :hash)))
               (concat "  " (propertize " Outdated: the file changed again on disk " 'face 'my-disk-notice-title)))
          (propertize "   n/p or click: select a change   q: return to the editor" 'face 'shadow)))

(defun my-disk-compare ()
  "Compare read-only snapshots of the editor and disk versions side by side."
  (interactive)
  (unless (my-disk-covered-p) (user-error "This buffer does not visit a local file"))
  (my-disk-check)
  (let* ((source (current-buffer))
         (disk (my-disk-read))
         (old (plist-get my-disk-compare :control)))
    (unless (cadr disk) (user-error "%s cannot be read from disk" (my-disk-name)))
    ;; Replace an open comparison instead of nesting another layout over it.
    (when (buffer-live-p old)
      (with-current-buffer old (ediff-really-quit nil)))
    (let* ((config (current-window-configuration))
           (editor (my-disk-snapshot "Editor Version" (my-disk-editor-text) major-mode source nil))
           (snapshot (my-disk-snapshot "Disk Version"
                                       (decode-coding-string (cadr disk) (or buffer-file-coding-system 'utf-8-unix))
                                       major-mode source (car disk)))
           (ediff-window-setup-function #'ediff-setup-windows-plain)
           (ediff-split-window-function #'split-window-horizontally))
      (ediff-buffers
       editor snapshot
       (list (lambda ()
               (let ((control (current-buffer)))
                 (use-local-map (copy-keymap (current-local-map)))
                 (local-set-key [remap ediff-quit] #'my-disk-quit)
                 (setq-local ediff-keep-variants t
                             ediff-window-setup-function #'ediff-setup-windows-plain
                             ediff-split-window-function #'split-window-horizontally)
                 (with-current-buffer source
                   (setq my-disk-compare (list :control control :hash (car disk))))
                 (my-disk-decorate)
                 (add-hook 'ediff-after-quit-hook-internal
                           (lambda ()
                             (mapc #'kill-buffer (seq-filter #'buffer-live-p (list editor snapshot)))
                             (when (buffer-live-p source)
                               (with-current-buffer source (setq my-disk-compare nil)))
                             (set-window-configuration config))
                           nil t))))))))

;;; Comparison display
;; Ediff finds and selects the differences; this layer aligns, colors, connects
;; and scrolls them.  Every difference takes the same number of screen rows in
;; both panes: the shorter side gets padding rows, displayed before the line
;; that follows it, so row R of one pane always faces row R of the other.

(defface my-disk-diff-added '((t :background "#aec49d" :extend t)) "Lines only in the disk version.")
(defface my-disk-diff-removed '((t :background "#cfa9a1" :extend t)) "Lines only in the editor version.")
(defface my-disk-diff-changed '((t :background "#a9b5cb" :extend t)) "Lines that differ between the versions.")
(defface my-disk-diff-padding '((t :background "#8a8982" :extend t))
  "Rows standing in for lines that only the other pane has.")
(defface my-disk-diff-selected '((t :background "#1c4642" :foreground "#dbe5df"))
  "Connector and overview marker of the selected difference.")
(defface my-disk-overview-view '((t :background "#5f5e57")) "Overview cells of the rows the panes show.")

(defvar-local my-disk-control nil "Snapshot: the Ediff control buffer comparing it.")
(defvar-local my-disk-pads nil "Snapshot: ((LINE . ROWS) ...) of padding shown before LINE, ascending.")
(defvar-local my-disk-diffs nil "Control: vector of (TYPE ROW HEIGHT (BEG-A END-A) (BEG-B END-B)).")
(defvar-local my-disk-selected nil "Control: index of the difference drawn as selected.")
(defvar-local my-disk-synced nil "Control: alist of pane window to the (START . VSCROLL) last seen or set.")

(defun my-disk-row (line pads)
  "First aligned row of LINE's display, its own padding included."
  (+ line -1 (cl-loop for (l . n) in pads while (< l line) sum n)))

(defun my-disk-line-at (row pads)
  "Return (LINE . OFFSET): the line whose display, padding included, covers ROW."
  (let ((before 0) line)
    (while (and pads (not line) (>= (- (1+ row) before) (caar pads)))
      (if (<= row (+ (caar pads) -1 before (cdar pads)))
          (setq line (caar pads))
        (cl-incf before (cdar pads))
        (pop pads)))
    (setq line (or line (- (1+ row) before)))
    (cons line (- row (+ line -1 before)))))

(defun my-disk-top (window &optional start)
  "Pixels from the first aligned row to the top of WINDOW."
  (with-current-buffer (window-buffer window)
    (+ (* (my-disk-row (line-number-at-pos (or start (window-start window)) t) my-disk-pads)
          (frame-char-height (window-frame window)))
       (window-vscroll window t))))

(defun my-disk-place (window top)
  "Scroll WINDOW so that its top is TOP pixels below the first aligned row."
  (with-current-buffer (window-buffer window)
    (let* ((height (frame-char-height (window-frame window)))
           (at (my-disk-line-at (/ top height) my-disk-pads))
           (start (save-excursion
                    (goto-char (point-min))
                    (and (zerop (forward-line (1- (car at)))) (point)))))
      (set-window-start window (or start (point-max)))
      ;; Kept by redisplay, so the top padding rows can scroll out of view.
      (set-window-vscroll window (if start (+ (* (cdr at) height) (% top height)) 0) t t))))

(defun my-disk-pane-state (window &optional start)
  (cons (or start (window-start window)) (window-vscroll window t)))

(defun my-disk-sync (window &optional start)
  "Scroll the other pane to the rows that WINDOW shows from START."
  (let ((control (buffer-local-value 'my-disk-control (window-buffer window))))
    (when (buffer-live-p control)
      (with-current-buffer control
        (let ((other (cond ((eq window ediff-window-A) ediff-window-B)
                           ((eq window ediff-window-B) ediff-window-A))))
          ;; A pane at the position last seen or set did not move: no echo back.
          (when (and (window-live-p other)
                     (not (equal (my-disk-pane-state window start) (alist-get window my-disk-synced))))
            (my-disk-place other (my-disk-top window start))
            (setq my-disk-synced (list (cons window (my-disk-pane-state window start))
                                       (cons other (my-disk-pane-state other))))
            (force-mode-line-update)))))))

(defun my-disk-cell (side face index)
  "A margin cell on SIDE painted with FACE, belonging to difference INDEX."
  (propertize " " 'my-disk-diff index
              'display `((margin ,side) ,(propertize " " 'face face 'my-disk-diff index))))

(defun my-disk-paint (index)
  "Draw difference INDEX in both snapshots: color, connector cells and padding."
  (pcase-let ((`(,type ,_ ,height ,a ,b) (aref my-disk-diffs index))
              (selected (eql index my-disk-selected)))
    (pcase-dolist (`(,buffer ,side (,beg ,end))
                   `((,ediff-buffer-A right-margin ,a) (,ediff-buffer-B left-margin ,b)))
      (with-current-buffer buffer
        (remove-overlays (point-min) (point-max) 'my-disk-diff index)
        (let* ((face (intern (format "my-disk-diff-%s" type)))
               (cell (my-disk-cell side (if selected 'my-disk-diff-selected face) index))
               (row (concat cell (propertize "\n" 'face 'my-disk-diff-padding)))
               (lines 0)
               overlays)
          (when (< beg end) (push (make-overlay beg end) overlays) (overlay-put (car overlays) 'face face))
          (save-excursion
            (goto-char beg)
            (while (< (point) end)
              (push (make-overlay (point) (point)) overlays)
              (overlay-put (car overlays) 'before-string cell)
              (cl-incf lines)
              (forward-line 1)))
          (when (< lines height)
            (push (make-overlay end end) overlays)
            (overlay-put (car overlays) 'before-string
                         (propertize
                          (if (save-excursion (goto-char end) (bolp))
                              (apply #'concat (make-list (- height lines) row))
                            ;; A last line without a newline: start the padding below it.
                            (concat "\n" (mapconcat #'identity (make-list (- height lines) cell) "\n")))
                          'my-disk-diff index)))
          (dolist (overlay overlays) (overlay-put overlay 'my-disk-diff index)))))))

(defun my-disk-decorate ()
  "Align, color and connect the differences of the current Ediff control buffer."
  ;; Only the selected difference keeps Ediff's own highlight; the rest show their kind.
  (setq-local ediff-highlight-all-diffs nil)
  (ediff-paint-background-regions 'unhighlight)
  (let ((shift-a 0) (shift-b 0) pads-a pads-b diffs)
    (dotimes (i ediff-number-of-differences)
      (let* ((a (list (ediff-get-diff-posn 'A 'beg i) (ediff-get-diff-posn 'A 'end i)))
             (b (list (ediff-get-diff-posn 'B 'beg i) (ediff-get-diff-posn 'B 'end i)))
             (lines-a (with-current-buffer ediff-buffer-A (apply #'count-lines a)))
             (lines-b (with-current-buffer ediff-buffer-B (apply #'count-lines b)))
             (height (max lines-a lines-b))
             (pad-line (lambda (end)
                         (save-excursion (goto-char end)
                                         (+ (line-number-at-pos nil t) (if (bolp) 0 1))))))
        (push (list (cond ((zerop lines-a) 'added) ((zerop lines-b) 'removed) (t 'changed))
                    (with-current-buffer ediff-buffer-A (+ (line-number-at-pos (car a) t) -1 shift-a))
                    height a b)
              diffs)
        (when (< lines-a height)
          (push (cons (with-current-buffer ediff-buffer-A (funcall pad-line (cadr a))) (- height lines-a)) pads-a)
          (cl-incf shift-a (- height lines-a)))
        (when (< lines-b height)
          (push (cons (with-current-buffer ediff-buffer-B (funcall pad-line (cadr b))) (- height lines-b)) pads-b)
          (cl-incf shift-b (- height lines-b)))))
    (setq my-disk-diffs (vconcat (nreverse diffs)) my-disk-selected nil my-disk-synced nil)
    (let ((control (current-buffer)))
      (pcase-dolist (`(,buffer ,pads ,window ,left ,right)
                     `((,ediff-buffer-A ,pads-a ,ediff-window-A 0 1) (,ediff-buffer-B ,pads-b ,ediff-window-B 1 0)))
        (with-current-buffer buffer
          (setq my-disk-control control my-disk-pads (nreverse pads)
                left-margin-width left right-margin-width right)
          (add-hook 'window-scroll-functions #'my-disk-sync nil t)
          ;; Pixel scrolling may change only the vscroll, which the hook above never sees.
          (add-hook 'pre-redisplay-functions #'my-disk-sync nil t)
          (when (window-live-p window) (set-window-margins window left right)))))
    (dotimes (i (length my-disk-diffs)) (my-disk-paint i))
    (setq-local header-line-format '(:eval (my-disk-overview)))
    (add-hook 'ediff-select-hook (lambda () (my-disk-mark ediff-current-difference)) nil t)
    (add-hook 'ediff-unselect-hook #'my-disk-mark nil t)))

(defun my-disk-mark (&optional index)
  "Draw difference INDEX as the selected one in both panes and the overview."
  (let ((old my-disk-selected))
    (setq my-disk-selected index)
    (dolist (i (delete-dups (delq nil (list old index)))) (my-disk-paint i))
    (force-mode-line-update t)))

;;; Overview and navigation

(defconst my-disk-overview-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-1] #'ignore)
    (define-key map [header-line mouse-1] #'my-disk-overview-click)
    map))

(defun my-disk-overview-strip (width)
  "WIDTH cells over all aligned rows: change markers, shading for the view."
  (let* ((total (with-current-buffer ediff-buffer-A
                  (let ((last (line-number-at-pos (point-max) t)))
                    (+ (my-disk-row last my-disk-pads) (alist-get last my-disk-pads 0) 1))))
         (pane ediff-window-A)
         (view (and (window-live-p pane) (/ (my-disk-top pane) (frame-char-height))))
         (rows (and view (window-body-height pane))))
    (mapconcat
     (lambda (cell)
       (let* ((from (/ (* cell total) width))
              (to (max (1+ from) (/ (* (1+ cell) total) width)))
              (index (cl-position-if (pcase-lambda (`(,_ ,row ,height . ,_))
                                       (and (< row to) (> (+ row height) from)))
                                     my-disk-diffs))
              (seen (and view (< from (+ view rows)) (> to view))))
         (propertize (if index "█" "·")
                     'face (append (when index
                                     `((:foreground ,(face-background
                                                      (if (eql index my-disk-selected) 'my-disk-diff-selected
                                                        (intern (format "my-disk-diff-%s" (car (aref my-disk-diffs index)))))
                                                      nil t))))
                                   (when seen '(my-disk-overview-view)))
                     'my-disk-cell (cons from index)
                     'mouse-face 'mode-line-highlight
                     'help-echo (if index (format "mouse-1: select change %d" (1+ index))
                                  "mouse-1: scroll both panes here")
                     'local-map my-disk-overview-map)))
     (number-sequence 0 (1- width)) "")))

(defun my-disk-overview ()
  "Control window header: the change counter, Previous and Next, and the overview."
  (let* ((count (length my-disk-diffs))
         (current ediff-current-difference)
         (head (concat (propertize (cond ((zerop count) " No differences ")
                                         ((< -1 current count) (format " Change %d of %d " (1+ current) count))
                                         (t (format " %d changes " count)))
                                   'face 'bold)
                       " " (my-disk-button "[◀ Previous]" "Select the previous change (p)"
                                           #'ediff-previous-difference)
                       " " (my-disk-button "[Next ▶]" "Select the next change (n)" #'ediff-next-difference)
                       "  ")))
    (concat head (and (> count 0) (my-disk-overview-strip (max 0 (- (window-width) (string-width head) 1)))))))

(defun my-disk-overview-click (event)
  "Select the change under the clicked overview cell, or scroll both panes there."
  (interactive "e")
  (let* ((posn (event-start event))
         (cell (get-text-property (cdr (posn-string posn)) 'my-disk-cell (car (posn-string posn)))))
    (with-current-buffer (window-buffer (posn-window posn))
      (if (cdr cell)
          (ediff-jump-to-difference (1+ (cdr cell)))
        (let ((pane ediff-window-A))
          (my-disk-place pane (* (max 0 (- (car cell) (/ (window-body-height pane) 2)))
                                 (frame-char-height (window-frame pane)))))))))

(defun my-disk-diff-at (buffer pos)
  "Index of the difference whose lines in snapshot BUFFER include POS."
  (with-current-buffer (buffer-local-value 'my-disk-control buffer)
    (let ((side (if (eq buffer ediff-buffer-A) 3 4)))
      (cl-position-if (lambda (diff) (pcase-let ((`(,beg ,end) (nth side diff))) (and (<= beg pos) (< pos end))))
                      my-disk-diffs))))

(defun my-disk-in-control (command &rest args)
  "Run Ediff COMMAND with ARGS for this snapshot, then return to this pane."
  (let ((buffer (current-buffer)))
    (with-current-buffer my-disk-control (apply command args))
    ;; Ediff rebuilds the panes and selects its control window.
    (when-let* ((window (and (buffer-live-p buffer) (get-buffer-window buffer))))
      (select-window window))))

(defun my-disk-select (index)
  (my-disk-in-control #'ediff-jump-to-difference (1+ index)))

(defun my-disk-select-at-point ()
  "Select the change at point in both panes."
  (interactive)
  (if-let* ((index (my-disk-diff-at (current-buffer) (point))))
      (my-disk-select index)
    (message "No change at point")))

(defun my-disk-select-click (event)
  "Move point to the click, and select the change there in both panes."
  (interactive "e")
  (let* ((posn (event-start event))
         (string (posn-string posn))
         (index (or (and string (get-text-property (cdr string) 'my-disk-diff (car string)))
                    (and (posn-point posn)
                         (my-disk-diff-at (window-buffer (posn-window posn)) (posn-point posn))))))
    (unless (posn-area posn) (mouse-set-point event))
    (when index
      (with-current-buffer (window-buffer (posn-window posn)) (my-disk-select index)))))

(defun my-disk-next () "Select the next change." (interactive) (my-disk-in-control #'ediff-next-difference))
(defun my-disk-previous () "Select the previous change." (interactive) (my-disk-in-control #'ediff-previous-difference))
(defun my-disk-quit ()
  "Close this read-only snapshot comparison without confirmation."
  (interactive)
  (with-current-buffer (or my-disk-control (current-buffer))
    (ediff-barf-if-not-control-buffer)
    (setq this-command 'ediff-quit)
    (ediff-really-quit nil)))

(defvar-keymap my-disk-snapshot-mode-map
  "RET" #'my-disk-select-at-point
  "n" #'my-disk-next
  "p" #'my-disk-previous
  "q" #'my-disk-quit
  "<mouse-1>" #'my-disk-select-click
  "<left-margin> <down-mouse-1>" #'ignore
  "<left-margin> <mouse-1>" #'my-disk-select-click
  "<right-margin> <down-mouse-1>" #'ignore
  "<right-margin> <mouse-1>" #'my-disk-select-click)

(define-minor-mode my-disk-snapshot-mode
  "Navigation keys of a read-only comparison snapshot."
  :keymap my-disk-snapshot-mode-map)

;;; Wiring

(defconst my-disk-map
  (let ((map (make-sparse-keymap)))
    (define-key map "c" #'my-disk-compare)
    (define-key map "r" #'my-disk-reload)
    (define-key map "k" #'my-disk-keep)
    (define-key map "l" #'my-disk-later)
    (define-key map "d" #'my-disk-review)
    (define-key map "m" #'my-disk-choose)
    map))
(global-set-key (kbd "C-c d") my-disk-map)

;; Visiting a changed file reuses its buffer; the notification replaces the prompt.
(setq query-about-changed-file nil)
(advice-add 'auto-revert-handler :around #'my-disk-auto-revert)
(add-hook 'first-change-hook #'my-disk-record-baseline)
(add-hook 'after-save-hook #'my-disk-reset)
(add-hook 'after-revert-hook #'my-disk-reset)
(add-hook 'window-buffer-change-functions #'my-disk-schedule)
(add-hook 'window-selection-change-functions #'my-disk-schedule)
(add-hook 'tab-bar-tab-post-select-functions #'my-disk-schedule)
(remove-function after-focus-change-function #'my-disk-schedule)
(add-function :after after-focus-change-function #'my-disk-schedule)
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (and (buffer-modified-p) (not my-disk-baseline)) (my-disk-record-baseline))))

(provide 'my-disk-changes)
;;; disk-changes.el ends here
