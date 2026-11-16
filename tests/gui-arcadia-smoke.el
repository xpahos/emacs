;;; gui-arcadia-smoke.el --- Render Arc gutter in an isolated GUI -*- lexical-binding: t; -*-
(setq user-emacs-directory
      (file-name-as-directory (or (getenv "EMACS_TEST_HOME")
                                  (error "EMACS_TEST_HOME is required"))))
(redisplay t)
(require 'eglot)
(defconst my-arc-gui-test-directory (file-name-directory load-file-name))
(load (expand-file-name "../init.el" my-arc-gui-test-directory) nil t)
(add-hook 'emacs-startup-hook
          (lambda ()
            (run-with-timer
             1 nil
             (lambda ()
               (let ((test-home (getenv "EMACS_TEST_HOME")))
                 (condition-case err
                     (progn
                       (load (expand-file-name "arcadia-smoke.el" my-arc-gui-test-directory) nil t)
                       (with-temp-file (expand-file-name "passed" test-home)
                         (insert "Arc gutter bitmap, line numbers and live diffs passed in GUI.\n"))
                       (kill-emacs 0))
                   (error
                    (with-temp-file (expand-file-name "failure" test-home)
                      (prin1 err (current-buffer)))
                    (kill-emacs 1))))))))
