;;; gui-session-smoke.el --- Separate-process GUI session check -*- lexical-binding: t; -*-
;; Run in three GUI processes with EMACS_TEST_PHASE=save, restore, closed,
;; using the same fresh EMACS_TEST_HOME directory.
(setq user-emacs-directory
      (file-name-as-directory (or (getenv "EMACS_TEST_HOME")
                                  (error "EMACS_TEST_HOME is required"))))
(defconst my-test-gui-init
  (expand-file-name "../init.el" (file-name-directory load-file-name)))
(load my-test-gui-init nil t)

(defun my-test-gui-session ()
  (condition-case err
      (let* ((phase (getenv "EMACS_TEST_PHASE"))
             (a (expand-file-name "a/service/" user-emacs-directory))
             (b (expand-file-name "b/service/" user-emacs-directory))
             (file-a (expand-file-name "first.txt" a))
             (hidden-a (expand-file-name "hidden.txt" a))
             (file-b (expand-file-name "second.txt" b)))
        (pcase phase
          ("save"
           (make-directory a t) (make-directory b t)
           (dolist (file (list file-a hidden-a file-b))
             (with-temp-file file (insert "saved\n")))
           (dotimes (i 200)
             (with-temp-file (expand-file-name (format "node-%03d.txt" i) a)))
           (make-directory (expand-file-name "browse/" a))
           (my-project-open a)
           (let ((editor (selected-window)))
             (dired-goto-file (expand-file-name "browse" a))
             (funcall (key-binding [mouse-2])
                      (list 'mouse-2 (list editor (point) '(0 . 0) 0)))
             (cl-assert (eq editor (selected-window)))
             (cl-assert (= (length (window-list)) 2))
             (dired a)
             (dired-goto-file file-a)
             (funcall (key-binding [mouse-2])
                      (list 'mouse-2 (list editor (point) '(0 . 0) 0)))
             (cl-assert (equal (buffer-file-name) file-a))
             (with-selected-window (split-window editor nil 'below)
               (dired a))
             (redisplay t)
             (cl-assert (= (length (window-list)) 2)))
           (find-file hidden-a) (bury-buffer) (find-file file-a)
           (let ((tree (treemacs-get-local-window)))
             (with-selected-window tree
               (dotimes (i 200)
                 (condition-case nil
                     (if (zerop (% i 2)) (scroll-up 10) (scroll-down 10))
                   (beginning-of-buffer nil) (end-of-buffer nil))
                 (redisplay t))))
           (my-project-open b) (find-file file-b)
           (load my-test-gui-init nil t)
           (cl-assert (= (length (tab-bar-tabs)) 3))
           (cl-assert (equal (buffer-file-name) file-b)))
          ("restore"
           (cl-assert (= (length (tab-bar-tabs)) 3))
           (tab-bar-select-tab-by-name "Start")
           (cl-assert (derived-mode-p 'dashboard-mode))
           (dolist (pair (list (cons a (list file-a hidden-a)) (cons b (list file-b))))
             (my-project-open (car pair))
             (cl-assert (= (length (tab-bar-tabs)) 3))
             (cl-assert (equal (alist-get 'my-project-root (tab-bar--current-tab))
                               (car pair)))
             (cl-assert
              (equal (sort (mapcar #'buffer-file-name (my-project-file-tabs)) #'string<)
                     (sort (copy-sequence (cdr pair)) #'string<)))
             (cl-assert (treemacs-get-local-window))
             (cl-assert
              (equal (mapcar #'treemacs-project->path
                             (treemacs-workspace->projects (treemacs-current-workspace)))
                     (list (directory-file-name (car pair))))))
           (tab-bar-close-tab))
          ("closed"
           (cl-assert (= (length (tab-bar-tabs)) 2))
           (cl-assert (seq-some (lambda (tab) (equal a (alist-get 'my-project-root tab)))
                               (tab-bar-tabs)))
           (cl-assert (not (seq-some (lambda (tab) (equal b (alist-get 'my-project-root tab)))
                                    (tab-bar-tabs))))
           (my-project-open b)
           (cl-assert (equal (mapcar #'buffer-file-name (my-project-file-tabs))
                             (list file-b)))))
        (run-with-timer
         7 nil
         (lambda ()
           (condition-case failure
               (progn
                 (cl-assert (file-exists-p tabspaces-session-file))
                 (with-temp-file (expand-file-name (concat phase ".passed") user-emacs-directory)
                   (insert "Session round trip and tree redraw passed.\n"))
                 (kill-emacs 0))
             (error
              (with-temp-file (expand-file-name "failure.txt" user-emacs-directory)
                (prin1 failure (current-buffer)))
              (kill-emacs 1))))))
    (error
     (with-temp-file (expand-file-name "failure.txt" user-emacs-directory)
       (prin1 err (current-buffer)))
     (kill-emacs 1))))

(add-hook 'emacs-startup-hook
          (lambda () (run-with-timer 1 nil #'my-test-gui-session)))
