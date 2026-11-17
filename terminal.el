;;; terminal.el --- Ghostel panel and working-copy shell history -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'ghostel)

(defvar my-shell-home (expand-file-name "~/.emacs/shell/"))
(defvar my-shell-python (or (executable-find "python3") "python3"))
(defvar my-shell-selected (make-hash-table :test #'equal))
(defvar my-shell-heights (make-hash-table :test #'equal))
(defvar my-shell-cleaned (make-hash-table :test #'equal))
(defvar-local my-shell-context-id nil)
(defvar-local my-shell-copy-id nil)
(defvar-local my-shell-name nil)
(defvar-local my-shell-directory nil)
(defvar-local my-shell-project-root nil)
(defvar-local my-shell-project-name nil)
(defvar-local my-shell-vcs nil)
(defvar-local my-shell-return-window nil)
(defvar-local my-shell-expanded-config nil)

;; Horizontal side windows must span both Treemacs and Pi.
(setq window-sides-vertical nil)
(add-to-list 'window-persistent-parameters '(my-shell-panel . writable))

(defun my-shell-context (copy directory)
  "Stable history namespace for COPY, or canonical DIRECTORY outside VCS."
  (cond ((equal (plist-get copy :role) "copy") (concat "copy:" (plist-get copy :copy_id)))
        ((plist-get copy :vcs) (concat "original:" (plist-get copy :project_id)))
        (t (concat "directory:" (file-name-as-directory (file-truename directory))))))

(defun my-shell-location ()
  "Return (CONTEXT COPY DIRECTORY) for the current working copy or folder."
  (if my-shell-context-id
      (list my-shell-context-id (and my-shell-copy-id (my-wt-copy my-shell-copy-id)) my-shell-directory)
    (let* ((copy (my-wt-tab-copy))
           (root (or (plist-get copy :directory) default-directory))
           (directory (if (and (not (file-remote-p default-directory))
                               (file-in-directory-p default-directory root))
                          default-directory root)))
      (when (file-remote-p root) (user-error "This shell configuration is for local folders"))
      (when (and copy (not (equal (plist-get copy :state) "ready")))
        (user-error "Working copy is %s" (plist-get copy :state)))
      (list (my-shell-context copy root) copy directory))))

(defun my-shell-window ()
  (seq-find (lambda (window) (window-parameter window 'my-shell-panel)) (window-list)))

(defun my-shell-display-buffer (buffer _alist)
  (with-current-buffer buffer
    (add-hook 'kill-buffer-hook #'my-shell-before-kill nil t)
    (setq-local tab-line-format nil window-size-fixed nil
                mouse-drag-copy-region 'non-empty select-enable-clipboard t
                header-line-format '(:eval (my-shell-header)))
    (display-buffer-in-side-window
     buffer `((side . bottom) (slot . 0)
              (window-height . ,(gethash my-shell-context-id my-shell-heights 0.42))
              (window-parameters . ((my-shell-panel . t) (no-other-window . t)
                                    (no-delete-other-windows . t)))))))

(defun my-shell-remember-height (&optional frame)
  (dolist (window (window-list frame 'no-minibuffer))
    (when (and (window-parameter window 'my-shell-panel)
               (eq (window-parameter window 'window-side) 'bottom))
      (with-current-buffer (window-buffer window)
        (when my-shell-context-id
          (puthash my-shell-context-id
                   (/ (float (window-total-height window)) (frame-height (window-frame window)))
                   my-shell-heights))))))

(defun my-shell-hide ()
  "Hide the panel without stopping its terminal."
  (interactive)
  (when-let* ((window (my-shell-window)))
    (with-current-buffer (window-buffer window)
      (when my-shell-expanded-config (my-shell-maximize))
      (my-shell-remember-height)
      (delete-window (my-shell-window))
      (when (window-live-p my-shell-return-window) (select-window my-shell-return-window)))))

(defun my-shell-maximize ()
  "Expand the terminal, or restore the exact previous window layout."
  (interactive)
  (unless my-shell-context-id (user-error "Select a shell first"))
  (if my-shell-expanded-config
      (let ((configuration my-shell-expanded-config))
        (setq my-shell-expanded-config nil)
        (set-window-configuration configuration))
    (my-shell-remember-height)
    (setq my-shell-expanded-config (current-window-configuration))
    (let ((buffer (current-buffer))
          (ignore-window-parameters t))
      (delete-other-windows)
      (set-window-parameter nil 'window-side nil)
      (set-window-parameter nil 'window-slot nil)
      (set-window-parameter nil 'my-shell-panel t)
      (set-window-buffer nil buffer))))

(defun my-shell-before-kill ()
  "Restore the editor before an exiting expanded terminal loses its layout."
  (when my-shell-expanded-config (my-shell-maximize))
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when (and (window-parameter window 'my-shell-panel)
               (not (one-window-p t (window-frame window))))
      (delete-window window))))

(defun my-shell-before-switch (&rest _)
  (when-let* ((window (my-shell-window)))
    (with-current-buffer (window-buffer window)
      (when my-shell-expanded-config (my-shell-maximize)))))

(defun my-shell-setup-project (copy)
  "Anchor the prompt and header to COPY's project, independently of shell cwd."
  (setq-local my-shell-project-root (or (plist-get copy :directory) my-shell-directory)
              my-shell-project-name
              (or (and copy (plist-get (my-wt-project (plist-get copy :project_id)) :name))
                  (file-name-nondirectory (directory-file-name my-shell-project-root)))
              my-shell-vcs (plist-get copy :vcs)))

(defun my-shell-refresh-branch (buffer _status)
  "Refresh the owning project's branch after a shell command completes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and my-shell-context-id my-shell-vcs)
        (when-let* ((copy (my-wt-copy my-shell-copy-id)))
          (my-wt-refresh-branch copy))))))

(defun my-shell-show (context copy directory name)
  "Show or create the named terminal, with ownership independent of later cd."
  (let* ((return (selected-window))
         (buffer (seq-find (lambda (buffer)
                             (and (equal (buffer-local-value 'my-shell-context-id buffer) context)
                                  (equal (buffer-local-value 'my-shell-name buffer) name)))
                           (buffer-list))))
    (unless buffer
      (unless (file-readable-p (expand-file-name "zsh/.zshrc" my-shell-home))
        (user-error "Shell config is missing: %szsh/.zshrc" my-shell-home))
      (let ((default-directory directory)
            (ghostel-shell '("/bin/zsh" "-d" "-i"))
            (ghostel-macos-login-shell nil)
            (ghostel-shell-integration nil)
            (process-environment
             (append (list (concat "ZDOTDIR=" (expand-file-name "zsh" my-shell-home))
                           (concat "MY_SHELL_HOME=" my-shell-home)
                           (concat "MY_SHELL_DB=" (expand-file-name "history.sqlite3" my-shell-home))
                           (concat "MY_SHELL_CONTEXT=" context)
                           (concat "MY_SHELL_NAME=" name)
                           (concat "MY_SHELL_PROJECT_ROOT=" (or (plist-get copy :directory) directory))
                           (concat "MY_SHELL_PYTHON=" my-shell-python))
                     process-environment)))
        (setq buffer
              (ghostel-create
               (format "*shell:%s:%s*" (file-name-nondirectory (directory-file-name directory)) name)
               (list (lambda (buffer alist)
                       (with-current-buffer buffer
                         (setq-local my-shell-context-id context
                                     my-shell-copy-id (plist-get copy :copy_id)
                                     my-shell-directory directory
                                     my-shell-name name)
                         (my-shell-setup-project copy))
                       (my-shell-display-buffer buffer alist)))
               `((kind . my-shell) (context . ,context) (name . ,name))))))
    (with-current-buffer buffer
      (unless (window-parameter return 'my-shell-panel)
        (setq my-shell-return-window return)))
    (puthash context buffer my-shell-selected)
    (my-shell-refresh-branch buffer nil)
    (select-window (or (get-buffer-window buffer) (my-shell-display-buffer buffer nil)))
    buffer))

(defun my-shell-toggle (&optional choose)
  "Show/focus the current terminal; hide when focused.  With prefix, select a name."
  (interactive "P")
  (if choose (my-shell-select)
    (if (window-parameter nil 'my-shell-panel) (my-shell-hide)
      (pcase-let* ((`(,context ,copy ,directory) (my-shell-location))
                   (buffer (gethash context my-shell-selected)))
        (my-shell-show context copy directory
                       (if (buffer-live-p buffer) (buffer-local-value 'my-shell-name buffer) "shell"))))))

(defun my-shell-select ()
  "Select an existing terminal or create one with a new name."
  (interactive)
  (pcase-let* ((`(,context ,copy ,directory) (my-shell-location))
               (names (delq nil (mapcar (lambda (buffer)
                                         (when (equal (buffer-local-value 'my-shell-context-id buffer) context)
                                           (buffer-local-value 'my-shell-name buffer))) (buffer-list))))
               (name (string-trim (completing-read "Terminal name: " names nil nil nil nil "shell"))))
    (when (string-empty-p name) (user-error "Enter a terminal name"))
    (when (and (my-shell-window)
               (buffer-local-value 'my-shell-expanded-config (window-buffer (my-shell-window))))
      (with-current-buffer (window-buffer (my-shell-window)) (my-shell-maximize)))
    (my-shell-show context copy directory name)))

(defun my-shell-header ()
  (let ((label (concat (or my-shell-project-name "")
                       (when my-shell-vcs
                         (concat " · " (my-wt-label (list :directory my-shell-project-root)))))))
    (concat " " (my-wt-header-button (concat my-shell-name " ▾ ") "Choose or create a named terminal" #'my-shell-select)
            "  " (propertize (truncate-string-to-width label (max 12 (- (window-width) (string-width my-shell-name) 16)) nil nil "…")
                             'help-echo label)
            (propertize " " 'display '(space :align-to (- right 10)))
            (my-wt-header-button " ↕ " "Expand / restore shell" #'my-shell-maximize)
            (my-wt-header-button " × " "Hide shell (C-c t)" #'my-shell-hide))))

(defun my-shell-after-select (&rest _)
  "Remove a foreign copy's panel if a tab layout carried it across."
  (when-let* ((window (my-shell-window))
              (root (alist-get 'my-project-root (tab-bar--current-tab))))
    (unless (equal (buffer-local-value 'my-shell-context-id (window-buffer window))
                   (my-shell-context (my-wt-copy-at root) root))
      (my-shell-hide))))

(defun my-shell-cleanup-copy (copy)
  "Delete histories only for a confirmed deleted COPY; retry failures on reconcile."
  (let ((id (plist-get copy :copy_id)))
    (when (and (equal (plist-get copy :role) "copy")
               (equal (plist-get copy :state) "deleted")
               (not (gethash id my-shell-cleaned)))
      (condition-case err
          (let ((process-environment (cons (concat "MY_SHELL_CONTEXT=copy:" id)
                                          (cons (concat "MY_SHELL_DB=" (expand-file-name "history.sqlite3" my-shell-home))
                                                process-environment))))
            (with-temp-buffer
              (unless (zerop (call-process my-shell-python nil (list (current-buffer) t) nil
                                          (expand-file-name "history.py" my-shell-home) "delete-worktree"))
                (error "%s" (string-trim (buffer-string))))
              (puthash id t my-shell-cleaned)))
        (error (display-warning 'my-shell
                 (format "Worktree %s deleted, but shell history cleanup failed: %s. Retry: M-x my-shell-retry-cleanup"
                         id (error-message-string err))))))))

(defun my-shell-retry-cleanup ()
  (interactive)
  (dolist (copy (my-wt--select "WHERE role='copy' AND state='deleted'" nil))
    (my-shell-cleanup-copy copy)))

(defun my-shell-theme ()
  (set-face-attribute 'ghostel-bold nil :weight 'semi-bold)
  (dolist (entry '((black . "#20211e") (red . "#632025") (green . "#19380f")
                   (yellow . "#4f2c0e") (blue . "#173568") (magenta . "#24534e")
                   (cyan . "#083b3a") (white . "#dbe5df")))
    (dolist (prefix '("ghostel-color-" "ghostel-color-bright-"))
      (set-face-attribute (intern (concat prefix (symbol-name (car entry)))) nil :foreground (cdr entry))))
  (ghostel-sync-theme))

(my-shell-theme)
(global-set-key (kbd "C-c t") #'my-shell-toggle)
(define-key ghostel-mode-map (kbd "C-c t") #'my-shell-toggle)
(define-key ghostel-semi-char-mode-map (kbd "C-c t") #'my-shell-toggle)
;; Keep clicks in terminal output from opening another window or application.
(define-key ghostel-link-map [mouse-1] nil)
(define-key ghostel-link-map [mouse-2] nil)
(add-hook 'window-size-change-functions #'my-shell-remember-height)
(add-hook 'tab-bar-tab-post-select-functions #'my-shell-after-select)
(add-hook 'my-wt-deleted-hook #'my-shell-cleanup-copy)
(add-hook 'ghostel-command-finish-functions #'my-shell-refresh-branch)
(advice-add 'my-wt-switch :after #'my-shell-after-select)
(advice-add 'my-wt-switch :before #'my-shell-before-switch)
(advice-add 'tab-bar-select-tab :before #'my-shell-before-switch)
(advice-add 'tab-bar-new-tab :before #'my-shell-before-switch)

(provide 'my-terminal)
