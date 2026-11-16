;;; gui-review-fixes-smoke.el --- Start screen startup/reload checks -*- lexical-binding: t; -*-
(setq user-emacs-directory
      (file-name-as-directory (or (getenv "EMACS_TEST_HOME")
                                  (error "EMACS_TEST_HOME required"))))
(redisplay t)
(require 'eglot)
(defvar my-test-start-refreshes 0)
(advice-add 'dashboard-insert-startupify-lists :before
            (lambda (&rest _) (cl-incf my-test-start-refreshes)))
(defconst my-test-review-init
  (expand-file-name "../init.el" (file-name-directory load-file-name)))
(load my-test-review-init nil t)

(add-hook
 'emacs-startup-hook
 (lambda ()
   (run-with-timer
    1 nil
    (lambda ()
      (condition-case err
          (progn
            (cl-assert (= my-test-start-refreshes 1))
            (cl-assert (derived-mode-p 'dashboard-mode))
            (setq my-test-start-refreshes 0)
            (load my-test-review-init nil t)
            (cl-assert (= my-test-start-refreshes 1))
            (cl-assert (eq (funcall initial-buffer-choice) (current-buffer)))
            (cl-assert (= my-test-start-refreshes 1))
            (let ((root (expand-file-name "fixture/" user-emacs-directory)))
              (make-directory root)
              (my-project-open root)
              (setq my-test-start-refreshes 0)
              (my-project-home)
              (redisplay t)
              (cl-assert (= my-test-start-refreshes 1))
              (cl-assert (derived-mode-p 'dashboard-mode))
              (setq my-test-start-refreshes 0)
              (my-project-home)
              (cl-assert (= my-test-start-refreshes 1))
              (my-project-open root)
              (setq my-test-start-refreshes 0)
              (tab-bar-select-tab-by-name "Start")
              (redisplay t)
              (cl-assert (= my-test-start-refreshes 1)))
            (with-temp-file (expand-file-name "passed" user-emacs-directory)
              (insert "GUI startup, reload, Home and tab selection refresh Start once.\n"))
            (kill-emacs 0))
        (error
         (with-temp-file (expand-file-name "failure" user-emacs-directory)
           (prin1 err (current-buffer)))
         (kill-emacs 1)))))))
