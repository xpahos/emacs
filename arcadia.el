;;; arcadia.el --- Arc integration and line gutters -*- lexical-binding: t; -*-

(add-to-list 'load-path (file-name-directory load-file-name))
(add-to-list 'load-path
             (expand-file-name "vendor/arcit" (file-name-directory load-file-name)))
(load (expand-file-name "vc-arc.el" (file-name-directory load-file-name)) nil t)
(setq arcit-arc-executable (expand-file-name "~/bin/arc"))
(add-to-list 'vc-handled-backends 'Arc)

(defun my-git-branch-label (formatter file)
  "Keep Git's branch label, face and tooltip, omitting the backend and indicator."
  (let ((vc-display-status 'no-backend))
    (substring (funcall formatter file) 1)))

(with-eval-after-load 'vc-git
  (advice-add 'vc-git-mode-line-string :around #'my-git-branch-label))

(defun my-arc-forget-invalid-backend (file)
  "Discard stale Arc state for FILE when it no longer belongs to Arc."
  (when (and (or (eq (vc-file-getprop file 'vc-backend) 'Arc)
                 (vc-file-getprop file 'vc-arc-registration-error)
                 (vc-file-getprop file 'vc-arc-state-error))
             (not (vc-arc-root file)))
    (vc-file-clearprops file)
    t))

(defun my-arc-safe-registration (registered file)
  "Leave VC's registration cache undecided when Arc is unavailable."
  (my-arc-forget-invalid-backend file)
  ;; Several opening/saving hooks query VC; one outage must not block each hook.
  (unless (> (or (vc-file-getprop file 'vc-arc-registration-retry-at) 0) (float-time))
    (condition-case err
        (prog1 (funcall registered file)
          (vc-file-setprop file 'vc-arc-registration-error nil)
          (vc-file-setprop file 'vc-arc-registration-retry-at nil))
      ;; Catch outside vc-registered, before it can cache a negative answer.
      (vc-arc-unavailable
       (vc-file-setprop file 'vc-arc-registration-error (error-message-string err))
       (vc-file-setprop file 'vc-arc-registration-retry-at (+ (float-time) 5))
       (message "%s" (error-message-string err))
       nil))))

(advice-add 'vc-registered :around #'my-arc-safe-registration)

(require 'diff-hl)
(require 'diff-hl-flydiff)
(setq diff-hl-update-async t
      diff-hl-disable-on-remote t
      diff-hl-flydiff-delay 0.8
      diff-hl-show-staged-changes t)

(defun my-arc-diff-update (update &rest args)
  "Keep existing markers when Arc cannot establish the file's state."
  (condition-case err
      (let ((file (diff-hl--buffer-file-name)))
        (when (and file (vc-file-getprop file 'vc-arc-registration-error))
          (vc-registered file))
        (let ((backend (and file (vc-backend file))))
          (when-let* ((failure (and file (vc-file-getprop file 'vc-arc-registration-error))))
            (signal 'vc-arc-unavailable (list failure)))
          (when (eq backend 'Arc)
            (if (vc-file-getprop file 'vc-arc-state-error)
                (vc-state-refresh file 'Arc)
              (vc-state file 'Arc))
            (when-let* ((failure (vc-file-getprop file 'vc-arc-state-error)))
              (signal 'vc-arc-unavailable (list failure)))))
        (apply update args))
    (vc-arc-unavailable
     ;; Flydiff must retry even if the buffer has not changed again.
     (setq diff-hl-flydiff-modified-tick nil)
     (message "%s" (error-message-string err)))))

(advice-add 'diff-hl-update :around #'my-arc-diff-update)

(define-fringe-bitmap 'my-diff-bar [7] 1 3 '(center t))
(defun my-diff-bar-bitmap (_type _position) 'my-diff-bar)
(setq diff-hl-fringe-bmp-function #'my-diff-bar-bitmap)
(dolist (face '((diff-hl-insert . "#355b32")
                (diff-hl-change . "#315777")
                (diff-hl-delete . "#85434a")))
  (set-face-attribute (car face) nil :inherit nil
                      :foreground (cdr face) :background "#999891"))
(set-face-attribute 'line-number nil :foreground "#45473f" :background "#999891")
(set-face-attribute 'line-number-current-line nil
                    :foreground "#20211e" :background "#b1b0a9" :weight 'bold)
(setq-default display-line-numbers-width 4
              display-line-numbers-grow-only t)

(defun my-code-gutter-setup ()
  "Show absolute line numbers only in editable file buffers."
  (when (and buffer-file-name
             (derived-mode-p 'prog-mode 'text-mode 'conf-mode))
    (setq-local display-line-numbers-type t)
    (display-line-numbers-mode 1)))

(add-hook 'find-file-hook #'my-code-gutter-setup)
(global-diff-hl-mode 1)
(diff-hl-flydiff-mode 1)

(defun my-vcs-status ()
  "Show repository status for the current file or directory."
  (interactive)
  (let* ((default-directory (if buffer-file-name
                                (file-name-directory buffer-file-name)
                              default-directory))
         (backend (vc-responsible-backend default-directory t))
         (root (and backend (vc-call-backend backend 'root default-directory))))
    (pcase backend
      ('nil (user-error "No version control repository in this directory"))
      ('Arc
       (let ((arcit--mount-path-alist `((nil . ,root))))
         (call-interactively #'arcit-status))
       ;; Arcit otherwise falls back to the first mounted repository on refresh.
       (setq-local arcit--mount-path-alist `((nil . ,root))))
      (_ (vc-dir (or root default-directory) backend)))))

(global-set-key (kbd "C-c v") #'my-vcs-status)

(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (my-code-gutter-setup)
    (when (and buffer-file-name
               (or (my-arc-forget-invalid-backend buffer-file-name)
                   (vc-arc-root buffer-file-name)))
      (vc-refresh-state)
      (when diff-hl-mode (diff-hl-update)))
    (when (and buffer-file-name (eq (vc-file-getprop buffer-file-name 'vc-backend) 'Git))
      (vc-mode-line buffer-file-name 'Git))))

(provide 'my-arcadia)
