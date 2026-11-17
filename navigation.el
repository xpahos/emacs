;;; navigation.el --- References over the editor -*- lexical-binding: t; -*-

(require 'xref)
(require 'thingatpt)

(set-face-attribute 'xref-match nil :inherit nil
                    :foreground "#173568" :background "#b1b0a9" :weight 'bold)

(when (and (eq system-type 'darwin)
           (not (fboundp 'my-navigation-command-held-p)))
  (module-load (expand-file-name "navigation-modifiers.so"
                                (file-name-directory load-file-name))))

(declare-function my-navigation-command-held-p "navigation-modifiers" ())
(defvar my-navigation-hover-overlay nil)
(defvar my-navigation-hover-timer nil)

(defun my-navigation-clear-hover ()
  "Remove the Command-hover underline."
  (when (overlayp my-navigation-hover-overlay)
    (delete-overlay my-navigation-hover-overlay)))

(defun my-navigation-update-hover ()
  "Underline the code symbol under the mouse while Command is held."
  (let (target)
    (when (and (my-navigation-command-held-p)
               (not (active-minibuffer-window)))
      (pcase-let ((`(,frame ,x . ,y) (mouse-pixel-position)))
        (when (and (frame-live-p frame) (frame-focus-state frame)
                   (not (frame-parent frame)) (natnump x) (natnump y))
          (let* ((position (posn-at-x-y x y frame))
                 (window (posn-window position))
                 (point (posn-point position)))
            (when (and (window-live-p window) (integerp point))
              (with-current-buffer (window-buffer window)
                (save-excursion
                  (goto-char point)
                  (when (and (derived-mode-p 'prog-mode)
                             (memq (char-syntax (or (char-after) ?\s)) '(?w ?_))
                             (not (nth 8 (syntax-ppss))))
                    (when-let* ((bounds (bounds-of-thing-at-point 'symbol)))
                      (setq target (list window (current-buffer) bounds)))))))))))
    (if (not target)
        (my-navigation-clear-hover)
      (pcase-let ((`(,window ,buffer (,begin . ,end)) target))
        (unless (overlayp my-navigation-hover-overlay)
          (setq my-navigation-hover-overlay (make-overlay begin end buffer)))
        (move-overlay my-navigation-hover-overlay begin end buffer)
        (overlay-put my-navigation-hover-overlay 'window window)
        (overlay-put my-navigation-hover-overlay 'face '(:underline t))
        (overlay-put my-navigation-hover-overlay 'pointer 'hand)))))

(when (timerp my-navigation-hover-timer)
  (cancel-timer my-navigation-hover-timer))
(my-navigation-clear-hover)
(when (and (not noninteractive) (fboundp 'my-navigation-command-held-p))
  (setq my-navigation-hover-timer
        (run-with-timer 0 0.08 #'my-navigation-update-hover)))

(defun my-references-popup (fetcher alist)
  "Show references from FETCHER over the source window described by ALIST."
  (let* ((xref-buffer-name "*References*")
         (display-buffer-alist
          (cons `("\\`\\*References\\*\\'"
                  (display-buffer-in-child-frame)
                  (child-frame-parameters
                   (width . 0.75) (height . 0.35) (left . 0.5) (top . 0.3)
                   (undecorated . t) (minibuffer . nil)
                   (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
                   (internal-border-width . 2)
                   (vertical-scroll-bars . ,(unless (eq system-type 'darwin) 'right))))
                display-buffer-alist))
         (buffer (xref--show-xref-buffer fetcher alist)))
    (with-current-buffer buffer
      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key [remap xref-goto-xref] #'xref-quit-and-goto-xref)
      (local-set-key [escape] #'quit-window)
      (local-set-key (kbd "C-g") #'quit-window)
      (local-set-key [down] #'xref-next-line-no-show)
      (local-set-key [up] #'xref-prev-line-no-show)
      (setq-local header-line-format " References    Enter: open    Esc: close"
                  tab-line-format nil
                  frame-auto-hide-function #'delete-frame)
      (goto-char (point-min))
      (xref-next-line-no-show))
    buffer))

(defun my-find-references-at-mouse (event)
  "Show uses of the identifier clicked by EVENT in a floating list."
  (interactive "e")
  (my-navigation-clear-hover)
  (when-let* ((buffer (get-buffer "*References*")))
    (dolist (window (get-buffer-window-list buffer nil t))
      (when (frame-parent (window-frame window))
        (delete-frame (window-frame window)))))
  (let ((xref-show-xrefs-function #'my-references-popup)
        (xref-auto-jump-to-first-xref nil))
    (xref-find-references-at-mouse event)))

(defun my-eglot-log-popup (buffer alist)
  "Display Messages or Eglot log BUFFER over the editor using ALIST."
  (when (display-graphic-p)
    (let* ((parent (or (frame-parent) (selected-frame)))
           (window
            (or (seq-find (lambda (window)
                            (eq (frame-parent (window-frame window)) parent))
                          (get-buffer-window-list buffer nil t))
                (with-selected-frame parent
                  (display-buffer-in-child-frame
                   buffer
                   (cons `(child-frame-parameters
                           (width . 0.75) (height . 0.35) (left . 0.5) (top . 0.3)
                           (undecorated . t) (minibuffer . nil)
                           (share-child-frame . eglot-log)
                           (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
                           (tab-bar-lines-keep-state . t)
                           (internal-border-width . 2)
                           (vertical-scroll-bars . ,(unless (eq system-type 'darwin) 'right)))
                         alist))))))
      (with-current-buffer buffer
        (use-local-map (copy-keymap (current-local-map)))
        (dolist (key '([escape] "\C-g" "q"))
          (local-set-key key #'quit-window))
        (setq-local header-line-format (if (equal (buffer-name) "*Messages*")
                                          " Messages    Esc / q: close"
                                        " Eglot log    Esc / q: close")
                    tab-line-format nil
                    frame-auto-hide-function #'delete-frame))
      (select-frame-set-input-focus (window-frame window))
      window)))

(add-to-list 'display-buffer-alist
             '("\\` ?\\*EGLOT .* \\(events\\|stderr\\)\\*\\'"
               (my-eglot-log-popup)))
(add-to-list 'display-buffer-alist
             '("\\`\\*Messages\\*\\'" (my-eglot-log-popup)))

(define-key prog-mode-map [s-down-mouse-1] #'ignore)
(define-key prog-mode-map [s-mouse-1] #'my-find-references-at-mouse)

(provide 'my-navigation)
