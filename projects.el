;;; projects.el --- Folder workspaces and project navigation -*- lexical-binding: t; -*-

(load (expand-file-name "shell-path.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)
(condition-case err
    (my-import-shell-path)
  (error (display-warning 'my-shell-path (error-message-string err))))

(require 'cl-lib)
(require 'project)
(require 'tab-bar)
(require 'tab-line)
(require 'recentf)
(require 'tabspaces)
(require 'treemacs)
(require 'treemacs-tab-bar)
(require 'dashboard)
(require 'dired)

(define-key dired-mode-map [mouse-2] #'dired-mouse-find-file)

(defun my-project-hide-directory-windows (frame)
  "Hide central directory panes in FRAME when a project file is visible."
  (with-selected-frame frame
    (when (and (alist-get 'my-project-root (tab-bar--current-tab))
               (seq-some (lambda (window)
                           (and (not (window-parameter window 'window-side))
                                (buffer-file-name (window-buffer window))))
                         (window-list frame 'nomini)))
      (dolist (window (window-list frame 'nomini))
        (when (and (not (window-parameter window 'window-side))
                   (not (window-dedicated-p window))
                   (with-current-buffer (window-buffer window)
                     (derived-mode-p 'dired-mode)))
          (delete-window window))))))

(add-hook 'window-buffer-change-functions #'my-project-hide-directory-windows)

(defun my-project-find (directory)
  "Use the longest remembered folder containing DIRECTORY as its project."
  (let* ((directory (file-name-as-directory (file-truename directory)))
         (roots (sort (copy-sequence (project-known-project-roots))
                      (lambda (a b) (> (length a) (length b)))))
         (root (seq-find (lambda (root)
                           (string-prefix-p (file-name-as-directory
                                             (expand-file-name root)) directory))
                         roots)))
    (when root (cons 'transient (expand-file-name root)))))

(cl-defmethod project-ignores :around ((project (head transient)) directory)
  "Exclude Cargo build artifacts from project enumeration and LSP watches."
  (let ((ignores (cl-call-next-method project directory)))
    (if (file-exists-p (expand-file-name "Cargo.toml" (project-root project)))
        (cons "target/" ignores)
      ignores)))

(defun my-project-tab-buffers (tab)
  "Return the live buffers belonging to TAB."
  (tabspaces--buffer-list nil (unless (eq (car tab) 'current-tab)
                               (tab-bar--tab-index tab))))

(defun my-project-file-tabs ()
  "Show only file buffers belonging to the active workspace."
  (seq-filter #'buffer-file-name
              (my-project-tab-buffers (tab-bar--current-tab))))

(defun my-copy-file-path (&optional relative)
  "Copy the current file's absolute path, or project-relative with RELATIVE."
  (interactive "P")
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (let* ((file (expand-file-name buffer-file-name))
         (path
          (if relative
              (let ((root (or (alist-get 'my-project-root (tab-bar--current-tab))
                              (when-let* ((project (project-current nil)))
                                (project-root project)))))
                (unless root (user-error "This file has no project"))
                (file-relative-name file root))
            file)))
    (kill-new path)
    (message "Copied path: %s" path)))

(defun my-copy-project-relative-path ()
  "Copy the current file's path relative to the active project root."
  (interactive)
  (my-copy-file-path t))

(defun my-project-files-state-file (root)
  "Return the private file list location for canonical project ROOT."
  (expand-file-name (concat "project-files/" (secure-hash 'sha256 root) ".eld")
                    user-emacs-directory))

(defun my-project-restore-files (root)
  "Reopen the files remembered when project ROOT was closed."
  (let ((state-file (my-project-files-state-file root))
        (tabspaces-session nil))
    (when (file-exists-p state-file)
      (with-demoted-errors "Project files could not be restored: %S"
        (let ((files (with-temp-buffer
                       (insert-file-contents state-file)
                       (let ((read-circle nil)) (read (current-buffer))))))
          (unless (and (listp files) (seq-every-p #'stringp files))
            (error "Invalid project file list"))
          ;; Restore in reverse MRU order so the last active file is selected.
          (dolist (file (reverse files))
            (when (and (not (file-remote-p file)) (file-readable-p file))
              (with-demoted-errors "File could not be restored: %S"
                (switch-to-buffer (find-file-noselect file))))))))))

(defun my-project-open (directory)
  "Open DIRECTORY in its project's tab, switching to it as the working copy."
  (interactive "DOpen folder: ")
  (unless (file-directory-p directory)
    (user-error "Folder does not exist: %s" directory))
  (let* ((root (file-name-as-directory (file-truename directory)))
         (copy (my-wt-register root))
         (project (plist-get copy :project_id))
         (tabs (tab-bar-tabs))
         ;; One visible tab per logical project, whichever copy it shows.
         (existing (seq-position tabs project
                                 (lambda (tab id)
                                   (equal (plist-get (my-wt-tab-copy tab) :project_id) id)))))
    (project-remember-project (cons 'transient root))
    (my-wt-reconcile project)
    (if existing
        (progn (tab-bar-select-tab (1+ existing))
               (my-wt-switch copy))
      (let* ((default-directory root)
             (base (plist-get (my-wt-project project) :name))
             (name base)
             (suffix 1))
        (while (seq-some (lambda (tab) (equal name (alist-get 'name tab))) tabs)
          (setq name (format "%s <%d>" base (cl-incf suffix))))
        (tab-bar-new-tab)
        (tab-bar-rename-tab name)
        (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) root)
        (dired root)
        (tabspaces-reset-buffer-list)
        ;; Renaming a tab changes Treemacs' scope identity.
        (treemacs-tab-bar--on-tab-switch)
        (let ((editor (selected-window)))
          (treemacs-add-and-display-current-project-exclusively)
          (select-window editor))
        (my-project-restore-files root)
        (my-wt-set-active copy)
        (my-wt-refresh-branch copy)))))

(defun my-project-switch ()
  "Select a recent project, or choose a new folder."
  (interactive)
  (my-project-open (project-prompt-project-dir)))

(defun my-project-start-buffer ()
  "Return a refreshed start screen."
  (dashboard-insert-startupify-lists t)
  (get-buffer dashboard-buffer-name))

(defun my-project-home ()
  "Show the permanent Start tab."
  (interactive)
  (let ((tab-bar-tab-post-select-functions
         (remq #'my-project-after-select tab-bar-tab-post-select-functions))
        (index (seq-position (tab-bar-tabs) "Start"
                             (lambda (tab name) (equal (alist-get 'name tab) name)))))
    (if index
        (tab-bar-select-tab (1+ index))
      (tab-bar-new-tab)
      (tab-bar-rename-tab "Start")))
  (switch-to-buffer (my-project-start-buffer)))

(defun my-project-keep-start (tab _last)
  "Keep the Start TAB available when all project tabs are closed."
  (and (not (alist-get 'my-project-root tab))
       (equal (alist-get 'name tab) "Start")))

(defun my-project-before-close (tab _last)
  "Close TAB's unshared files, preserving the tab if a close is canceled.
Each working copy's file list is saved under its own root."
  (when-let* ((root (alist-get 'my-project-root tab)))
    (let* ((own (my-project-tab-buffers tab))
           (copies (ignore-errors (my-wt-copies (plist-get (my-wt-tab-copy tab) :project_id))))
           ;; Inactive copies of this project keep their buffers in saved states.
           (inactive (delq nil (mapcar (lambda (copy)
                                         (let ((dir (plist-get copy :directory)))
                                           (unless (equal dir root)
                                             (when-let* ((state (gethash dir my-wt-states)))
                                               (cons dir (append (nth 1 state) (nth 2 state)))))))
                                       copies)))
           (others (delq tab (copy-sequence (tab-bar-tabs))))
           (shared (mapcan #'my-project-tab-buffers others))
           (doomed (seq-filter (lambda (b) (and (buffer-live-p b) (buffer-file-name b) (not (memq b shared))))
                               (delete-dups (apply #'append own (mapcar #'cdr inactive))))))
      ;; Capture the lists before killing buffers, including hidden/shared files.
      (my-wt-save-files root own)
      (dolist (entry inactive) (my-wt-save-files (car entry) (cdr entry)))
      ;; `kill-buffer' from Lisp does not ask about unsaved edits, so ask here,
      ;; before anything is closed; declining cancels the whole close.
      (when-let* ((modified (seq-filter #'buffer-modified-p doomed)))
        (dolist (buffer modified)
          (unless (with-current-buffer buffer (run-hook-with-args-until-failure 'kill-buffer-query-functions))
            (user-error "Project close canceled")))
        (save-some-buffers nil (lambda () (memq (current-buffer) modified)))
        (dolist (buffer modified)
          (when (and (buffer-modified-p buffer)
                     (not (yes-or-no-p (format "Discard unsaved changes in %s? " (buffer-name buffer)))))
            (user-error "Project close canceled"))))
      (dolist (buffer doomed)
        (unless (kill-buffer buffer)
          (user-error "Project close canceled")))
      ;; Only a completed close forgets the inactive copies' layouts.
      (dolist (entry inactive) (remhash (car entry) my-wt-states)))))

(defun my-project-after-select (_previous tab)
  "Refresh recent projects on returning to the start TAB."
  (when (equal (alist-get 'name tab) "Start")
    (my-project-start-buffer)))

(defun my-project-session-roots (&rest _)
  "Record explicit roots before Tabspaces writes the session."
  (my-wt-save-inactive)
  (setq tabspaces-project-tab-map
        (delq nil
              (mapcar (lambda (tab)
                        (when-let* ((root (alist-get 'my-project-root tab)))
                          (cons root (alist-get 'name tab))))
                      (tab-bar-tabs)))))

(defun my-project-save-parent-session (save-function &rest args)
  "Save the editor's session even while a floating child frame has focus."
  (with-selected-frame (or (frame-parent) (selected-frame))
    (apply save-function args)))

(defun my-project-restored-root (root)
  "ROOT, or its project's original directory when that copy is gone."
  (if (or (not root) (file-remote-p root) (file-directory-p root)) root
    (when-let* ((copy (ignore-errors (my-wt-copy-at root)))
                (original (my-wt-original (plist-get copy :project_id))))
      (message "Working copy %s is unavailable; showing %s" root (plist-get original :directory))
      (plist-get original :directory))))

(defun my-project-session-trees (&rest _)
  "Reconnect restored tabs to their explicit roots and file trees."
  (let ((selected (alist-get 'name (tab-bar--current-tab))))
    (dolist (tab (tab-bar-tabs))
      (let* ((name (alist-get 'name tab))
             (root (my-project-restored-root (car (rassoc name tabspaces-project-tab-map)))))
        (when (equal name "Start")
          (my-project-home))
        (when (and root (not (file-remote-p root)) (file-directory-p root))
          (ignore-errors (my-wt-set-active (my-wt-register root) t))
          (tab-bar-select-tab-by-name name)
          (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) root)
          (project-remember-project (cons 'transient root))
          (let ((default-directory root)
                (editor (selected-window)))
            (treemacs-tab-bar--on-tab-switch)
            (treemacs-add-and-display-current-project-exclusively)
            (when (window-live-p editor) (select-window editor))))))
    (tab-bar-select-tab-by-name selected)))

(defun my-project-skip-missing-file (restore record)
  "Do not RESTORE a file RECORD that no longer exists; visiting it would create it on save."
  (unless (and (stringp record) (not (file-remote-p record)) (not (file-exists-p record)))
    (funcall restore record)))

(defun my-project-restore-session ()
  "Restore the saved workspaces once the graphical frame is ready."
  (when (file-exists-p tabspaces-session-file)
    (condition-case err
        (let ((tabspaces-session nil))
          (tabspaces-restore-session tabspaces-session-file))
      (error (message "Session restore failed: %s" (error-message-string err))))))

(setq tabspaces-default-tab "Start"
      tabspaces-include-buffers nil
      tabspaces-use-filtered-buffers-as-default t
      tabspaces-session t
      tabspaces-session-file (expand-file-name "tabsession.el" user-emacs-directory)
      tabspaces-session-project-session-store nil
      ;; Saving visits every tab, so keep it out of short typing pauses.
      tabspaces-session-auto-save-delay 60
      ;; Restore after the tree scope and graphical frame are initialized.
      tabspaces-session-auto-restore nil
      tabspaces-initialize-project-with-todo nil
      tab-bar-new-tab-choice "*scratch*"
      tab-bar-format '(tab-bar-format-tabs tab-bar-separator)
      tab-bar-close-tab-select 'recent
      tab-line-tabs-function #'my-project-file-tabs
      tab-line-close-tab-function #'kill-buffer
      tab-line-exclude-modes '(treemacs-mode dashboard-mode dired-mode special-mode)
      treemacs-width 30
      treemacs-no-png-images t
      treemacs-persist-file (expand-file-name "treemacs-persist" user-emacs-directory)
      recentf-max-saved-items 100
      recentf-auto-cleanup 'never
      dashboard-projects-backend 'project-el
      dashboard-projects-switch-function #'my-project-open
      dashboard-projects-show-base t
      dashboard-remove-missing-entry nil
      dashboard-items '((projects . 10) (recents . 8))
      dashboard-item-names '(("Projects:" . "Recent projects:")
                             ("Recent Files:" . "Recent files:"))
      dashboard-startupify-list '(dashboard-insert-newline
                                  dashboard-insert-navigator
                                  dashboard-insert-newline
                                  dashboard-insert-items)
      dashboard-navigator-buttons
      '(((nil "Open folder…" "Open a project in a new tab"
              (lambda (&rest _) (call-interactively #'my-project-open)))
         (nil "Open file…" "Open a standalone file"
              (lambda (&rest _) (call-interactively #'find-file)))))
      initial-buffer-choice (lambda () (or (get-buffer dashboard-buffer-name)
                                          (my-project-start-buffer)))
      inhibit-startup-screen t)

(add-hook 'project-find-functions #'my-project-find)
(unless tab-bar-mode (tab-bar-mode 1))
(unless tabspaces-mode (tabspaces-mode 1))
(unless (eq (treemacs-current-scope-type) 'treemacs-tab-bar-scope)
  (treemacs-set-scope-type 'Tabs))
(treemacs-follow-mode 1)
(treemacs-filewatch-mode 1)
(global-tab-line-mode 1)
(recentf-mode 1)
(add-hook 'tab-bar-tab-prevent-close-functions #'my-project-keep-start)
(add-hook 'tab-bar-tab-pre-close-functions #'my-project-before-close)
(add-hook 'tab-bar-tab-post-select-functions #'my-project-after-select)
(advice-add 'tabspaces-save-session :before #'my-project-session-roots)
(advice-add 'tabspaces-save-session :around #'my-project-save-parent-session)
(advice-add 'tabspaces-restore-session :after #'my-project-session-trees)
(advice-add 'tabspaces--restore-buffer-record :around #'my-project-skip-missing-file)
;; Unmodified buffers follow external checkouts; modified ones keep the user's
;; edits and report the conflict through Emacs' supersession check.
(global-auto-revert-mode 1)
(unless noninteractive
  (add-hook 'kill-emacs-hook #'tabspaces--save-session-smart)
  (tabspaces--setup-session-auto-save)
  (add-hook 'emacs-startup-hook #'my-project-restore-session))

(global-set-key (kbd "C-c o") #'my-project-open)
(global-set-key (kbd "C-x p p") #'my-project-switch)
(global-set-key (kbd "C-c h") #'my-project-home)
(global-set-key (kbd "C-c q") #'tab-bar-close-tab)
(global-set-key (kbd "C-c p f") #'my-copy-file-path)
(global-set-key (kbd "C-c p r") #'my-copy-project-relative-path)
(global-set-key (kbd "<f8>") #'treemacs)
(define-key tabspaces-command-map (kbd "o") #'my-project-open)
(define-key tabspaces-command-map (kbd "k") #'tab-bar-close-tab)

(add-to-list 'treesit-extra-load-path "/opt/local/lib")
(require 'eglot)
(setq eglot-autoshutdown t
      eglot-sync-connect nil)
(add-to-list 'eglot-server-programs
             '((c-mode c-ts-mode c++-mode c++-ts-mode) "clangd"))

(cl-defmethod eglot-register-capability
  (_server (_method (eql workspace/didChangeWatchedFiles)) _id &rest _)
  "Decline file watches: listing a large root with `find' blocks Emacs.
After an external checkout, use \\[eglot-reconnect]."
  nil)
(add-to-list 'auto-mode-alist '("\\.go\\'" . go-ts-mode))
(defun my-go-font-lock-setup ()
  "Colour calls, variable uses and fields as well as Go declarations."
  (setq-local treesit-font-lock-level 4)
  (treesit-font-lock-recompute-features)
  (font-lock-flush))

(add-hook 'go-ts-mode-hook #'my-go-font-lock-setup)
(add-hook 'go-ts-mode-hook #'eglot-ensure)
(add-hook 'rust-ts-mode-hook #'eglot-ensure)
(dolist (hook '(c-mode-hook c++-mode-hook c-ts-mode-hook c++-ts-mode-hook))
  (add-hook hook #'eglot-ensure))

(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'go-ts-mode)
      (my-go-font-lock-setup))
    (when (derived-mode-p 'rust-ts-mode 'c-mode 'c++-mode 'c-ts-mode 'c++-ts-mode)
      (eglot-ensure))))

;; Translate the existing home tab when reloading without restarting Emacs.
(dolist (tab (tab-bar-tabs))
  (when (and (not (alist-get 'my-project-root tab))
             (equal (alist-get 'name tab) "Старт"))
    (setf (alist-get 'name (cdr tab)) "Start")))
(if (and (= (length (tab-bar-tabs)) 1)
         (not (alist-get 'my-project-root (tab-bar--current-tab))))
    (progn
      (tab-bar-rename-tab "Start")
      (my-project-home))
  (my-project-start-buffer))

(load (expand-file-name "worktrees.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(load (expand-file-name "worktree-ui.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)
(provide 'my-projects)
