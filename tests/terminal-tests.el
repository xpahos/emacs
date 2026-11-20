;;; terminal-tests.el --- Terminal ownership and layout -*- lexical-binding: t; -*-
(load (expand-file-name "worktrees-tests.el" (file-name-directory load-file-name)) nil t)
(load (expand-file-name "terminal.el" my-wt-test-config) nil t)

(ert-deftest my-shell-command-click-opens-links-from-an-unselected-terminal ()
  (let ((file (make-temp-file "shell-link-" nil ".txt" "first\nsecond\n"))
        (shell (generate-new-buffer "*shell-link-test*"))
        opened)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((editor (selected-window))
                 (terminal (my-shell-display-buffer shell nil))
                 (windows (window-list))
                 (split-height-threshold 0)
                 (split-width-threshold nil)
                 (position (list terminal 1 '(0 . 0) 0)))
            (dolist (uri (list "https://example.org/" (concat "fileref:" file ":2:3")
                              (concat "file://" file "#L2C3")))
              (with-current-buffer shell
                (erase-buffer)
                (insert (propertize "link" 'keymap ghostel-link-map 'help-echo uri)))
              (select-window editor)
              (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
                (funcall (lookup-key ghostel-link-map [s-down-mouse-1]) (list 's-down-mouse-1 position))
                (should-not opened)
                (funcall (lookup-key ghostel-link-map [s-mouse-1]) (list 's-mouse-1 position)))
              (if (string-prefix-p "https:" uri)
                  (progn (should (equal opened uri)) (setq opened nil))
                (should (equal (buffer-file-name) file))
                (should (= (line-number-at-pos) 2))
                (should (= (current-column) 2))
                (should (eq (selected-window) editor)))
              (should (seq-set-equal-p windows (window-list) #'eq))
              (should (eq (window-buffer terminal) shell))
              (set-window-buffer editor (get-buffer-create "*scratch*")))))
      (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer))
      (kill-buffer shell)
      (delete-file file))))

(ert-deftest my-shell-plain-clicks-do-not-open-links ()
  (dolist (key '([mouse-1] [mouse-2]))
    (should-not (lookup-key ghostel-link-map key))))

(ert-deftest my-shell-context-survives-branch-and-separates-copies ()
  (should (equal (my-shell-context '(:role "original" :vcs "git" :project_id "p" :branch "main") "/tmp/")
                 (my-shell-context '(:role "original" :vcs "git" :project_id "p" :branch "x") "/tmp/")))
  (should (equal (my-shell-context '(:role "original" :vcs "git" :project_id "p") "/tmp/") "original:p"))
  (should (equal (my-shell-context '(:role "copy" :vcs "git" :copy_id "x") "/tmp/") "copy:x"))
  (should (equal (my-shell-context nil "/private/tmp/") "directory:/private/tmp/")))

(ert-deftest my-shell-header-follows-the-owned-project-branch-after-cd ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (copy (my-wt-register repo)))
     (with-temp-buffer
       (setq-local my-shell-copy-id (plist-get copy :copy_id)
                   my-shell-context-id (concat "original:" (plist-get copy :project_id))
                   my-shell-directory (expand-file-name "sub/" repo) my-shell-name "shell")
       (my-shell-setup-project copy)
       (my-test-shell-refresh (current-buffer))
       (should (string-match-p "repo · main" (my-shell-header)))
       (should (equal my-shell-project-root repo))
       (setq default-directory tmp)
       (my-wt-test-git repo "switch" "-c" "feature/gds")
       (my-test-shell-refresh (current-buffer))
       (should (string-match-p "repo · feature/gds" (my-shell-header)))))))

(defun my-test-shell-refresh (buffer)
  (remhash (buffer-local-value 'my-shell-project-root buffer) my-wt-branches)
  (my-shell-refresh-branch buffer 0)
  (my-wt-test-wait (lambda () (gethash (buffer-local-value 'my-shell-project-root buffer) my-wt-branches))))

(ert-deftest my-shell-full-width-toggle-retains-buffer-and-restores-layout ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((my-shell-heights (make-hash-table :test #'equal))
           (buffer (generate-new-buffer "*shell-layout-test*"))
           (left (display-buffer-in-side-window (get-buffer-create "*tree-test*") '((side . left) (window-width . 15))))
           (right (display-buffer-in-side-window (get-buffer-create "*pi-test*") '((side . right) (window-width . 20)))))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq-local my-shell-context-id "directory:/private/tmp/" my-shell-name "shell"))
            (let ((panel (my-shell-display-buffer buffer nil)))
              (should (= (window-total-width panel) (window-total-width (frame-root-window))))
              (should (<= (nth 3 (window-edges left)) (nth 1 (window-edges panel))))
              (should (<= (nth 3 (window-edges right)) (nth 1 (window-edges panel))))
              (select-window panel)
              (my-shell-maximize)
              (should (= (length (window-list)) 1))
              (my-shell-maximize)
              (should (= (length (window-list)) 4))
              (my-shell-hide)
              (should (buffer-live-p buffer))
              (should-not (get-buffer-window buffer))
              (should (numberp (gethash "directory:/private/tmp/" my-shell-heights)))))
        (kill-buffer buffer)))))

(ert-deftest my-shell-owned-process-is-released-after-cd-outside ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register repo))
          (copy (my-wt-test-git-copy source "shell-test"))
          (buffer (generate-new-buffer "*owned-shell-test*"))
          (process (make-pipe-process :name "native-pty-event-pipe" :buffer buffer :noquery t)))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (setq-local default-directory "/private/tmp/" my-shell-copy-id (plist-get copy :copy_id)
                         my-shell-context-id (concat "copy:" (plist-get copy :copy_id))))
           (should (memq buffer (my-wt-copy-buffers copy)))
           (should (seq-some (lambda (message) (string-match-p "Processes still run" message))
                             (my-wt-delete-blockers copy)))
           (with-current-buffer buffer
             (setq major-mode 'ghostel-mode)
             (setq-local ghostel--process process))
           (should-not (my-wt-delete-blockers copy))
           (my-wt-release copy)
           (should-not (buffer-live-p buffer))
           (should-not (process-live-p process)))
       (when (process-live-p process) (delete-process process))
       (kill-buffer buffer)))))

(ert-deftest my-shell-cleanup-only-after-confirmed-deletion ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register repo))
          (copy (my-wt-test-git-copy source "shell-test"))
          (id (plist-get copy :copy_id))
          (my-wt-deleted-hook nil)
          deleted)
     (add-hook 'my-wt-deleted-hook (lambda (copy) (push (plist-get copy :copy_id) deleted)))
     (my-wt-update id :state "unavailable")
     (should-not deleted)
     (my-wt-update id :state "ready")
     (my-wt-test-git repo "worktree" "remove" (directory-file-name (plist-get copy :vcs_root)))
     (my-wt-reconcile (plist-get source :project_id))
     (should (equal (plist-get (my-wt-copy id) :state) "deleted"))
     (should (member id deleted)))))

(ert-deftest my-shell-interrupted-delete-does-not-erase-unavailable-copy ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register repo))
          (copy (my-wt-test-git-copy source "shell-test"))
          (id (plist-get copy :copy_id))
          (my-wt-deleted-hook nil)
          deleted)
     (add-hook 'my-wt-deleted-hook (lambda (_) (setq deleted t)))
     (my-wt-update id :state "deleting")
     ;; A missing mount point is not proof of VCS removal.
     (rename-file (plist-get copy :vcs_root) (concat (directory-file-name (plist-get copy :vcs_root)) "-offline"))
     (my-wt-reconcile (plist-get source :project_id))
     (should-not deleted)
     (should (equal (plist-get (my-wt-copy id) :state) "unavailable")))))

(ert-deftest my-shell-moving-worktree-preserves-history ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (source (my-wt-register repo))
          (copy (my-wt-test-git-copy source "shell-test"))
          (my-wt-deleted-hook nil)
          deleted)
     (add-hook 'my-wt-deleted-hook (lambda (_) (setq deleted t)))
     (my-wt-test-git repo "worktree" "move" (directory-file-name (plist-get copy :vcs_root)) (expand-file-name "moved" tmp))
     (my-wt-reconcile (plist-get source :project_id))
     (should-not deleted)
     (should (equal (plist-get (my-wt-copy (plist-get copy :copy_id)) :state) "unavailable")))))

(ert-deftest my-shell-folder-selection-stays-anchored-after-cd ()
  (my-wt-test
   (with-temp-buffer
     (setq-local my-shell-context-id "directory:/private/tmp/"
                 my-shell-directory "/private/tmp/" my-shell-name "shell"
                 default-directory tmp)
     (should (equal (car (my-shell-location)) "directory:/private/tmp/"))
     (should-not (memq (current-buffer) (my-wt-copy-buffers (list :copy_id "other" :vcs_root tmp)))))))

(ert-deftest my-shell-copy-switch-restores-expanded-source-first ()
  (my-wt-test
   (let* ((repo (my-wt-test-repo (expand-file-name "repo/" tmp)))
          (_ (my-project-open repo))
          (source (my-wt-tab-copy))
          (copy (my-wt-test-git-copy source "shell-test"))
          (buffer (generate-new-buffer "*expanded-shell-test*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (setq-local my-shell-context-id (concat "original:" (plist-get source :project_id))
                         my-shell-copy-id (plist-get source :copy_id) my-shell-name "shell"))
           (select-window (my-shell-display-buffer buffer nil))
           (my-shell-maximize)
           (my-wt-switch copy)
           (should-not (get-buffer-window buffer))
           (should (equal default-directory (plist-get copy :directory)))
           (my-wt-switch source)
           (should (get-buffer-window buffer))
           (should (> (length (window-list)) 1))
           (should-not (buffer-local-value 'my-shell-expanded-config buffer)))
       (kill-buffer buffer)))))

(ert-deftest my-shell-exiting-expanded-shell-restores-editor ()
  (save-window-excursion
    (delete-other-windows)
    (let ((buffer (generate-new-buffer "*exiting-expanded-shell*")))
      (with-current-buffer buffer (setq-local my-shell-context-id "directory:/private/tmp/" my-shell-name "shell"))
      (select-window (my-shell-display-buffer buffer nil))
      (my-shell-maximize)
      (kill-buffer buffer)
      (should-not (my-shell-window))
      (should-not (window-parameter (selected-window) 'my-shell-panel)))))

(ert-deftest my-shell-inactive-exit-does-not-replace-another-tab ()
  (my-wt-test
   (let ((buffer (generate-new-buffer "*inactive-expanded-shell*"))
         (other (generate-new-buffer "*other-project-editor*")))
     (unwind-protect
         (progn
           (with-current-buffer buffer (setq-local my-shell-context-id "directory:/private/tmp/" my-shell-name "shell"))
           (select-window (my-shell-display-buffer buffer nil))
           (my-shell-maximize)
           (tab-bar-new-tab)
           (switch-to-buffer other)
           (kill-buffer buffer)
           (should (eq (window-buffer (selected-window)) other))
           (should-not (my-shell-window)))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (kill-buffer other)))))
