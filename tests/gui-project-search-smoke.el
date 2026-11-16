;;; gui-project-search-smoke.el --- Real directory file picker check -*- lexical-binding: t; -*-
(setq user-emacs-directory
      (file-name-as-directory (or (getenv "EMACS_TEST_HOME")
                                  (error "EMACS_TEST_HOME is required"))))
(redisplay t)
(require 'eglot)
(load (expand-file-name "../init.el" (file-name-directory load-file-name)) nil t)

(defun my-test-project-file-picker ()
  (condition-case err
      (let* ((root (expand-file-name "~/arc/cloudia/cloud/compute/go/"))
             (expected (expand-file-name "common/pkg/hw/pci/class.go" root))
             (go-ts-mode-hook (remove #'eglot-ensure go-ts-mode-hook))
             (origin (get-buffer-create "*search-origin*")))
        (switch-to-buffer origin)
        (setf (alist-get 'my-project-root (cdr (tab-bar--current-tab-find))) root)
        (dolist (query '("cloud/compute/go/common/pkg/hw/pci/class.go"
                         "go/common/pkg/hw/pci/class.go"
                         "common/pkg/hw/pci/class.go"))
          (let (driver)
            (unwind-protect
                (minibuffer-with-setup-hook
                    (lambda ()
                      (insert query)
                      (setq driver
                            (run-with-timer
                             0.1 0.1
                             (lambda ()
                               (when (active-minibuffer-window)
                                 (with-selected-window (active-minibuffer-window)
                                   (when (test-completion expected minibuffer-completion-table
                                                          minibuffer-completion-predicate)
                                     (cancel-timer driver)
                                     (icomplete-exhibit)
                                     (call-interactively (key-binding (kbd "RET"))))))))))
                  (call-interactively (key-binding (kbd "C-c p o"))))
              (when (timerp driver) (cancel-timer driver))))
          (cl-assert (equal buffer-file-name expected))
          (cl-assert (= (length (window-list)) 1)))
        (let ((before (current-buffer)))
          (condition-case nil
              (minibuffer-with-setup-hook
                  (lambda () (run-at-time 0.05 nil #'abort-recursive-edit))
                (my-project-find-file))
            (quit nil))
          (cl-assert (eq before (current-buffer)))
          (cl-assert (= (length (window-list)) 1))
          (cl-assert (not (seq-some (lambda (p)
                                     (and (process-live-p p)
                                          (string-prefix-p "project-files" (process-name p))))
                                   (process-list)))))
        (let ((before (current-buffer)) reported)
          (cl-letf (((symbol-function 'my-project-search-source)
                     (lambda (_) '("/private/tmp/" "/bin/sh" "-c" "exit 7"))))
            (condition-case nil (my-project-find-file)
              (user-error (setq reported t))))
          (cl-assert reported)
          (cl-assert (eq before (current-buffer)))
          (cl-assert (= (length (window-list)) 1)))
        (with-temp-file (expand-file-name "passed" user-emacs-directory)
          (insert "Filesystem search: three path fragments, cancellation and process failure passed without replacing the editor with a directory.\n"))
        (kill-emacs 0))
    (error
     (with-temp-file (expand-file-name "failure" user-emacs-directory)
       (prin1 err (current-buffer)))
     (kill-emacs 1))))

(add-hook 'emacs-startup-hook
          (lambda () (run-with-timer 1 nil #'my-test-project-file-picker)))
