;;; gui-eglot-popup-smoke.el --- Floating message and Eglot log checks -*- lexical-binding: t; -*-
(setq user-emacs-directory
      (file-name-as-directory (or (getenv "EMACS_TEST_HOME") (error "Test home required"))))
(redisplay t)
(require 'eglot)
(load (expand-file-name "../init.el" (file-name-directory load-file-name)) nil t)
(require 'ert)

(defun my-test-eglot-popup ()
  (condition-case err
      (let* ((parent (selected-frame))
             (source (selected-window))
             (windows (window-list parent))
             (tabs (length (tab-bar-tabs parent))))
        (dolist (kind '("messages" "events" "stderr"))
          (let ((buffer (if (equal kind "messages") (messages-buffer)
                          (get-buffer-create (format "*EGLOT (popup-test) %s*" kind)))))
            (with-current-buffer buffer
              (unless (equal kind "messages") (special-mode))
              (let ((inhibit-read-only t))
                (insert "go command required, not found\n")))
            (dolist (key '([escape] "\C-g" "q"))
              (let* ((window (cond
                              ((equal kind "messages")
                               (call-interactively
                                (lookup-key minibuffer-inactive-mode-map [mouse-1])))
                              ((equal kind "events")
                                 (progn
                                   (funcall (eglot--mouse-call #'eglot-events-buffer)
                                            (list 'mouse-1 (list source 'mode-line '(20 . 20) 0)))
                                   (get-buffer-window buffer t)))
                              (t (display-buffer buffer))))
                     (popup (window-frame window)))
                (should (eq (frame-parent popup) parent))
                (should (equal windows (window-list parent)))
                (should (= tabs (length (tab-bar-tabs parent))))
                (should-not (buffer-local-value 'tab-line-format buffer))
                (tab-bar-mode 1)
                (should (= 0 (frame-parameter popup 'tab-bar-lines)))
                (with-selected-window source
                  (should (eq window (display-buffer buffer))))
                (select-frame-set-input-focus popup)
                (select-window window)
                (should (string-match-p "go command required" (buffer-string)))
                (call-interactively (key-binding key))
                (should-not (frame-live-p popup))
                (should (buffer-live-p buffer))
                (should (eq (selected-window) source))))
            (unless (equal kind "messages") (kill-buffer buffer))))
        (with-temp-file (expand-file-name "passed" user-emacs-directory)
          (insert "Echo-area click and Eglot logs float, reuse, preserve layout and close without losing logs.\n"))
        (kill-emacs 0))
    (error
     (with-temp-file (expand-file-name "failure" user-emacs-directory)
       (prin1 err (current-buffer)))
     (kill-emacs 1))))

(add-hook 'emacs-startup-hook
          (lambda () (run-with-timer 1 nil #'my-test-eglot-popup)))
