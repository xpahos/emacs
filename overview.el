;;; overview.el --- Clickable whole-file markers beside the scrollbar -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'flymake)
(require 'svg)

(defconst my-overview-width 16)
(defconst my-overview-colors
  '((note . "#315777") (warning . "#72521e") (error . "#85434a")
    (insert . "#355b32") (change . "#315777") (delete . "#85434a")))
(defvar-local my-overview-cache nil)
(defvar my-overview-views nil)
(defvar my-overview-timer nil)
(cl-defstruct my-overview-view window frame buffer margin applied signature)
;; Project sessions save margins; keep their original value to avoid accumulating space.
(add-to-list 'window-persistent-parameters '(my-overview-margin . writable))

(defun my-overview-data ()
  "Return (LINE-COUNT . MARKS), caching line calculations between changes.
Each mark is (FIRST-LINE LAST-LINE TYPE POSITION)."
  (save-restriction
    (widen)
    (let (entries)
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (cond
         ((overlay-get overlay 'flymake-diagnostic)
          (let* ((diag (overlay-get overlay 'flymake-diagnostic))
                 (kind (pcase (flymake-diagnostic-type diag)
                         (:error 'error) (:warning 'warning) (_ 'note)))
                 (pos (overlay-start overlay)))
            (push (list pos pos kind) entries)))
         ((overlay-get overlay 'diff-hl-hunk)
          (push (list (overlay-start overlay)
                      (max (overlay-start overlay) (1- (overlay-end overlay)))
                      (overlay-get overlay 'diff-hl-hunk-type)) entries))))
      (setq entries (sort entries
                          (lambda (a b)
                            (if (= (car a) (car b))
                                (string< (symbol-name (nth 2 a))
                                         (symbol-name (nth 2 b)))
                              (< (car a) (car b))))))
      (let ((key (list (buffer-chars-modified-tick) entries)))
        (unless (equal key (car my-overview-cache))
          (save-excursion
            (goto-char (point-min))
            (let ((line 1) (previous (point-min)) marks)
              ;; Count consecutive spans once, rather than rescan from BOF per mark.
              (dolist (entry entries)
                (goto-char (car entry))
                (let ((bol (line-beginning-position)))
                  (cl-incf line (count-lines previous bol))
                  (setq previous bol)
                  (push (list line
                              (+ line (count-lines bol
                                                   (progn (goto-char (nth 1 entry))
                                                          (line-beginning-position))))
                              (nth 2 entry) (car entry)) marks)))
              (setq my-overview-cache
                    (cons key (cons (line-number-at-pos (point-max) t)
                                    (nreverse marks)))))))
        (cdr my-overview-cache)))))

(defun my-overview-y (line total height)
  "Map LINE of TOTAL to a pixel in a stripe of HEIGHT pixels."
  (round (* (max 0 (- height 3)) (/ (float (1- line)) (max 1 (1- total))))))

(defun my-overview-target (data height x y)
  "Return the nearest marker position in DATA at X,Y, or nil for empty space."
  (let ((distance 7) target)
    (dolist (mark (cdr data))
      (when (eq (< x 8) (not (memq (nth 2 mark) '(insert change delete))))
        (let* ((top (my-overview-y (car mark) (car data) height))
               (bottom (+ 3 (my-overview-y (cadr mark) (car data) height)))
               (delta (max 0 (- top y) (- y bottom))))
          (when (< delta distance)
            (setq distance delta target (nth 3 mark))))))
    target))

(defun my-overview-click (event)
  "Jump to the marker or proportional file line clicked by EVENT."
  (interactive "e")
  (let* ((position (event-start event))
         (frame (window-frame (posn-window position)))
         (view (frame-parameter frame 'my-overview-view))
         (window (and view (my-overview-view-window view)))
         (xy (posn-object-x-y position)))
    (when (and (window-live-p window) xy)
      (let* ((data (with-current-buffer (window-buffer window) (my-overview-data)))
             (height (frame-pixel-height frame))
             (target (my-overview-target data height (car xy) (cdr xy))))
        (select-frame-set-input-focus (window-frame window))
        (select-window window)
        (widen)
        (if target
            (goto-char (min target (point-max)))
          (goto-char (point-min))
          (forward-line (round (* (1- (car data))
                                  (/ (float (cdr xy)) (max 1 (- height 3)))))))
        (recenter)))))

(defvar my-overview-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'ignore)
    (define-key map [mouse-1] #'my-overview-click)
    map))

(defun my-overview-create (window)
  "Create a non-focusing stripe for WINDOW."
  (let* ((saved (window-parameter window 'my-overview-margin))
         (margin (cdr (window-margins window)))
         (buffer (generate-new-buffer " *File overview*"))
         (view (make-my-overview-view :window window :buffer buffer
                                     :margin (if (and saved (equal margin (car saved)))
                                                 (cdr saved) margin)
                                     :applied (car saved)))
         (parent (window-frame window)))
    (with-current-buffer buffer
      (special-mode)
      (use-local-map my-overview-map)
      (setq-local mode-line-format nil header-line-format nil tab-line-format nil
                  cursor-type nil display-line-numbers nil
                  left-margin-width 0 right-margin-width 0
                  truncate-lines t buffer-undo-list t))
    (condition-case err
        (let ((frame
               (make-frame
                `((parent-frame . ,parent) (my-overview-view . ,view)
                  (minibuffer . nil) (visibility . nil)
                  (width . (text-pixels . 16)) (height . (text-pixels . 100))
                  (min-width . 1) (min-height . 1)
                  (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t)
                  (no-other-frame . t) (desktop-dont-save . t)
                  (skip-taskbar . t) (unsplittable . t)
                  (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
                  (internal-border-width . 0) (border-width . 0)
                  (left-fringe . 0) (right-fringe . 0)
                  (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
                  (background-color . ,(face-background 'default parent t))))))
          (setf (my-overview-view-frame view) frame)
          (set-window-buffer (frame-root-window frame) buffer)
          (set-window-fringes (frame-root-window frame) 0 0)
          (set-window-hscroll (frame-root-window frame) 0)
          (set-window-dedicated-p (frame-root-window frame) t)
          (push view my-overview-views)
          view)
      (error (kill-buffer buffer) (signal (car err) (cdr err))))))

(defun my-overview-remove (view)
  "Remove VIEW and restore its source window's margin."
  (let ((window (my-overview-view-window view)))
    (when (window-live-p window)
      (when (equal (cdr (window-margins window)) (my-overview-view-applied view))
        (set-window-margins window (car (window-margins window))
                            (my-overview-view-margin view)))
      (set-window-parameter window 'my-overview-margin nil)))
  (when (frame-live-p (my-overview-view-frame view))
    (delete-frame (my-overview-view-frame view) t))
  (when (buffer-live-p (my-overview-view-buffer view))
    (kill-buffer (my-overview-view-buffer view)))
  (setq my-overview-views (delq view my-overview-views)))

(defun my-overview-render (view)
  "Position VIEW beside the native scrollbar and refresh changed markers."
  (let* ((window (my-overview-view-window view))
         (parent (window-frame window))
         (frame (my-overview-view-frame view))
         (margins (window-margins window))
         (char-width (frame-char-width parent))
         ;; Redisplay reserves a character after the image even without a cursor.
         (stripe-width (+ my-overview-width (frame-char-width frame))))
    (unless (equal (cdr margins) (my-overview-view-applied view))
      (setf (my-overview-view-margin view) (cdr margins)))
    (let ((width (+ (or (my-overview-view-margin view) 0)
                    (ceiling stripe-width char-width))))
      (set-window-margins window (car margins) width)
      (setf (my-overview-view-applied view) width)
      (set-window-parameter window 'my-overview-margin
                            (cons width (my-overview-view-margin view))))
    (pcase-let* ((`(,_ ,top ,right ,bottom) (window-inside-pixel-edges window))
                 (`(,_ ,right-fringe ,outside) (window-fringes window))
                 (height (- bottom top))
                 (x (+ right (if outside 0 right-fringe)
                       (* char-width (cdr (window-margins window)))
                       (- stripe-width)))
                 (data (with-current-buffer (window-buffer window) (my-overview-data)))
                 (background (face-background 'default parent t))
                 (signature (list height background data)))
      (unless (and (equal (frame-parameter frame 'left) x)
                   (equal (frame-parameter frame 'top) top))
        (set-frame-position frame x top))
      (unless (and (= (frame-pixel-width frame) stripe-width)
                   (= (frame-pixel-height frame) height))
        (set-frame-size frame stripe-width height t))
      (unless (equal signature (my-overview-view-signature view))
        (let ((svg (svg-create my-overview-width height)))
          (svg-rectangle svg 0 0 my-overview-width height :fill background)
          (svg-line svg 7 0 7 height :stroke "#898880" :stroke-width 1)
          ;; Paint errors last so they remain visible when diagnostics overlap.
          (dolist (color my-overview-colors)
            (dolist (mark (cdr data))
              (when (eq (nth 2 mark) (car color))
                (let ((y (my-overview-y (car mark) (car data) height)))
                  (svg-rectangle
                   svg (if (memq (car color) '(insert change delete)) 9 1) y 6
                   (max 3 (- (+ 3 (my-overview-y (cadr mark) (car data) height)) y))
                   :fill (cdr color))))))
          (with-current-buffer (my-overview-view-buffer view)
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert-image (svg-image svg :ascent 100 :scale 1))
              (put-text-property (point-min) (point-max) 'pointer 'hand)
              (goto-char (point-min))))
          (set-window-hscroll (frame-root-window frame) 0)
          (set-window-start (frame-root-window frame) 1))
        (setf (my-overview-view-signature view) signature))
      (unless (eq (frame-visible-p frame) t) (make-frame-visible frame)))))

(defun my-overview-refresh ()
  "Synchronize stripes with visible file windows without changing selection."
  (save-selected-window
    (let (windows)
      (dolist (frame (frame-list))
        (when (and (display-graphic-p frame) (not (frame-parent frame))
                   (eq (frame-visible-p frame) t))
          (dolist (window (window-list frame 'no-minibuffer))
            (when (and (not (window-parameter window 'window-side))
                       (> (window-body-width window) 12)
                       (> (window-body-height window t) 40)
                       (with-current-buffer (window-buffer window)
                         (and buffer-file-name
                              (not (derived-mode-p 'special-mode 'dired-mode)))))
              (push window windows)))))
      (dolist (view (copy-sequence my-overview-views))
        (unless (and (memq (my-overview-view-window view) windows)
                     (frame-live-p (my-overview-view-frame view)))
          (my-overview-remove view)))
      (dolist (window windows)
        (let ((view (or (cl-find window my-overview-views :key #'my-overview-view-window)
                        (my-overview-create window))))
          (my-overview-render view))))))

(defun my-overview-idle-refresh ()
  "Avoid rendering while the user is typing or scrolling."
  (when (and (current-idle-time) (> (float-time (current-idle-time)) 0.15))
    (condition-case err
        (my-overview-refresh)
      (error
       (my-overview-mode -1)
       (message "File overview disabled: %s" (error-message-string err))))))

(define-minor-mode my-overview-mode
  "Show clickable diagnostics and diff markers beside native scrollbars."
  :global t :group 'convenience
  (when (timerp my-overview-timer) (cancel-timer my-overview-timer))
  (setq my-overview-timer nil)
  (dolist (view (copy-sequence my-overview-views)) (my-overview-remove view))
  (when (and my-overview-mode (not noninteractive) (image-type-available-p 'svg))
    (setq my-overview-timer (run-with-timer 0.5 0.5 #'my-overview-idle-refresh))))

(my-overview-mode 1)
(provide 'my-overview)
