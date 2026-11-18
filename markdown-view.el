;;; markdown-view.el --- Native Markdown preview and editing -*- lexical-binding: t; -*-

(require 'markdown-ts-mode)
(require 'cl-lib)

(add-to-list 'treesit-extra-load-path
             (expand-file-name "tree-sitter" (file-name-directory load-file-name)))

(defun my-markdown-toggle-at-mouse (event)
  "Toggle Markdown in the window whose header received EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (my-markdown-toggle)))

(defvar my-markdown-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'my-markdown-toggle-at-mouse)
    map))

(dolist (face '(markdown-ts-code-block markdown-ts-code-block-markup-hidden
                markdown-ts-in-code-block))
  (set-face-attribute face nil :inherit 'fixed-pitch :background "#aaa9a2"
                      :foreground 'unspecified :box nil :extend nil))

(defun my-markdown-clear-code-panels ()
  "Remove display-only code borders before changing major modes."
  (save-restriction
    (widen)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'my-markdown-code-edge) (delete-overlay ov))
      (when (overlay-get ov 'markdown-ts-code-block)
        (dolist (property '(before-string after-string line-prefix wrap-prefix))
          (overlay-put ov property nil))))))

(defun my-markdown-update-wrapped-panels (window)
  "Extend wide code panels to the right edge of WINDOW, including wrapped rows."
  (with-selected-window window
    (save-restriction
      (widen)
      (let ((width (- (window-body-width window t) (line-number-display-width t))))
        (dolist (ov (overlays-in (point-min) (point-max)))
          (when (and (overlay-get ov 'my-markdown-code-edge)
                     (overlay-get ov 'window)
                     (or (eq (overlay-get ov 'window) window)
                         (not (window-live-p (overlay-get ov 'window)))))
            (delete-overlay ov)))
        (dolist (block (overlays-in (point-min) (point-max)))
          (when (and (overlay-get block 'markdown-ts-code-block)
                     (> (or (overlay-get block 'my-markdown-code-width) 0) width))
            (let ((ov (make-overlay (overlay-start block) (overlay-end block))))
              (overlay-put ov 'my-markdown-code-edge t)
              (overlay-put ov 'window window)
              (overlay-put ov 'priority 21)
              (overlay-put ov 'face '(:background "#aaa9a2" :extend t)))))))))

(defun my-markdown-style-code-panels ()
  "Fit native code panels to their text, with display-only padding."
  (when (eq major-mode 'markdown-ts-view-mode)
    (save-excursion
      (save-restriction
        (widen)
        (my-markdown-clear-code-panels)
        (font-lock-ensure)
        (dolist (block (overlays-in (point-min) (point-max)))
          (when (overlay-get block 'markdown-ts-code-block)
            (goto-char (overlay-start block))
            (skip-chars-forward " \t" (overlay-end block))
            (let* ((fence (treesit-parent-until
                          (treesit-node-at (point) 'markdown)
                          (lambda (node) (equal (treesit-node-type node) "fenced_code_block"))))
                   (indent (if fence
                               (save-excursion
                                 (goto-char (treesit-node-start fence))
                                 (- (point) (line-beginning-position)))
                             0))
                   (source (replace-regexp-in-string
                            (format "^ \\{0,%d\\}" indent) ""
                            (buffer-substring (overlay-start block) (overlay-end block))))
                   (width (+ 6 (string-pixel-width source (current-buffer))))
                   (margin (propertize " " 'display '(space :width (6)) 'face 'default))
                   (prefix (concat margin (propertize " " 'display '(space :width (4))
                                                      'face 'markdown-ts-code-block)))
                   (suffix (propertize " " 'display `(space :align-to (,(+ width 6)))
                                       'face 'markdown-ts-code-block))
                   (cap (concat (propertize (copy-sequence margin) 'display '(space :width (6) :height (5)))
                                (propertize " " 'display `(space :width (,width) :height (5)))))
                   (top (copy-sequence cap))
                   (bottom (copy-sequence cap)))
              (put-text-property 1 2 'face
                                 '(:background "#aaa9a2" :overline "#8b8a83" :extend nil) top)
              (put-text-property 1 2 'face
                                 '(:background "#aaa9a2" :underline (:color "#8b8a83" :position t) :extend nil) bottom)
              (overlay-put block 'line-prefix prefix)
              (overlay-put block 'wrap-prefix prefix)
              (overlay-put block 'my-markdown-code-width (+ width 6))
              ;; Real fence newlines keep single-line scrolling out of overlay strings.
              (dolist (delimiter (and fence (treesit-node-children fence)))
                (when (equal (treesit-node-type delimiter) "fenced_code_block_delimiter")
                  (goto-char (treesit-node-start delimiter))
                  (let* ((end (line-end-position))
                         (opening (< end (overlay-start block)))
                         (ov (make-overlay end (min (1+ end) (point-max)))))
                    (overlay-put ov 'my-markdown-code-edge t)
                    (overlay-put ov 'my-markdown-code-cap (if opening 'top 'bottom))
                    (overlay-put ov 'invisible 'my-markdown-code-edge)
                    (overlay-put ov 'face 'default)
                    (overlay-put ov 'line-height t)
                    (overlay-put ov 'before-string
                                 (propertize (if opening top bottom)
                                             'line-prefix "" 'wrap-prefix "")))))
              (goto-char (overlay-start block))
              (while (< (point) (overlay-end block))
                (let ((start (point)))
                  (skip-chars-forward " " (min (+ start indent) (line-end-position)))
                  (when (> (point) start)
                    (let ((ov (make-overlay start (point))))
                      (overlay-put ov 'my-markdown-code-edge t)
                      (overlay-put ov 'display ""))))
                (let* ((end (line-end-position))
                       (ov (make-overlay end (min (1+ end) (point-max)))))
                  (overlay-put ov 'my-markdown-code-edge t)
                  ;; A tinted newline otherwise paints one extra glyph past the panel.
                  (overlay-put ov 'face 'default)
                  (overlay-put ov 'priority '(nil . 20))
                  (overlay-put ov 'before-string suffix))
                (forward-line 1)))))))
    (add-hook 'window-size-change-functions #'my-markdown-update-wrapped-panels nil t)
    (dolist (window (get-buffer-window-list nil nil t))
      (my-markdown-update-wrapped-panels window))))

(defun my-markdown-set-mode (preview)
  "Show this buffer as PREVIEW or editable Markdown without changing text."
  (let ((starts (mapcar (lambda (window) (cons window (window-start window)))
                       (get-buffer-window-list nil nil t)))
        ;; The stock view hook appends a newline, which would modify the file.
        ;; shortcut: final headings can lose styling until the grammar handles EOF.
        (markdown-ts-view-mode-pre-init-hook nil))
    (save-mark-and-excursion
      (save-restriction
        (widen)
        (if preview (markdown-ts-view-mode) (markdown-ts-mode))))
    (when preview (treesit-font-lock-recompute-features '(image-preview)))
    (setq buffer-read-only preview)
    (setq-local header-line-format
                (list " "
                      (propertize (if preview " Preview  [ Edit ] " " Edit  [ Preview ] ")
                                  'local-map my-markdown-header-map
                                  'mouse-face 'highlight
                                  'help-echo "Toggle preview / editing (C-c C-x C-m)")
                      "    C-c C-x C-m"))
    (visual-line-mode 1)
    (setq-local line-spacing 0.12)
    (when preview
      (my-markdown-style-code-panels)
      (add-hook 'change-major-mode-hook #'my-markdown-clear-code-panels nil t)
      (add-hook 'after-revert-hook #'my-markdown-style-code-panels nil t))
    ;; Preview derives from special-mode, excluded by our global file tab setup.
    (when (bound-and-true-p global-tab-line-mode) (tab-line-mode 1))
    (dolist (entry starts) (set-window-start (car entry) (cdr entry) t))))

(defun my-markdown-open ()
  "Open Markdown in preview, or plain text when its grammars are missing."
  (interactive)
  (if (and (treesit-language-available-p 'markdown)
           (treesit-language-available-p 'markdown-inline))
      (my-markdown-set-mode t)
    (text-mode)
    (message "Markdown preview needs grammars: M-x markdown-ts-mode-install-parsers")))

(defun my-markdown-toggle ()
  "Switch between native Markdown preview and editing in the current tab."
  (interactive)
  (unless (derived-mode-p 'markdown-ts-mode)
    (user-error "This buffer is not in Markdown mode"))
  (when (and (eq major-mode 'markdown-ts-view-mode)
             buffer-file-name (file-exists-p buffer-file-name)
             (not (file-writable-p buffer-file-name)))
    (user-error "File is read-only: %s" buffer-file-name))
  (my-markdown-set-mode (not (eq major-mode 'markdown-ts-view-mode))))

(dolist (map (list markdown-ts-mode-map markdown-ts-view-mode-map))
  (define-key map (kbd "C-c C-x C-m") #'my-markdown-toggle))

(dolist (entry '((markdown-ts-heading-1 . 1.35)
                 (markdown-ts-heading-2 . 1.2)
                 (markdown-ts-heading-3 . 1.1)))
  (set-face-attribute (car entry) nil :height (cdr entry)))

(add-to-list 'auto-mode-alist '("\\.\\(?:md\\|markdown\\)\\'" . my-markdown-open))

(provide 'my-markdown-view)
