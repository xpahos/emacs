;;; shell-path.el --- Import executable paths from the login shell -*- lexical-binding: t; -*-

(defun my-shell-path (shell flags)
  "Return PATH from SHELL started with FLAGS, allowing five seconds."
  (let ((default-directory (expand-file-name "~/"))
        (deadline (+ (float-time) 5))
        process)
    (with-temp-buffer
      (unwind-protect
          (progn
            (setq process
                  (make-process
                   :name "shell-path" :buffer (current-buffer)
                   :command (list shell flags
                                  "printf '\\000EMACS_PATH\\000%s\\000' \"$PATH\"")
                   :connection-type 'pipe :noquery t :sentinel #'ignore))
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.05))
            (when (process-live-p process)
              (error "Shell PATH import timed out after 5 seconds"))
            (unless (and (eq (process-status process) 'exit)
                         (zerop (process-exit-status process)))
              (error "Shell PATH import failed: %s" shell))
            (goto-char (point-min))
            ;; Startup scripts may print prompts and terminal control sequences.
            (unless (re-search-forward "\0EMACS_PATH\0\\([^\0]+\\)\0" nil t)
              (error "Shell did not return a nonempty PATH"))
            (match-string-no-properties 1))
        (when (and process (process-live-p process))
          (delete-process process))))))

(defun my-import-shell-path ()
  "Import the login shell PATH, adding missing paths from Bash startup files."
  (interactive)
  (let* ((shell (or (getenv "SHELL") shell-file-name))
         (bash-primary (equal (file-name-nondirectory shell) "bash"))
         (paths (list (my-shell-path shell "-lic"))))
    ;; A separate non-login Bash reads .bashrc even if its profile does not.
    (dolist (flags (if bash-primary '("-ic") '("-lic" "-ic")))
      (condition-case err
          (setq paths (append paths
                              (list (my-shell-path (if bash-primary shell "/bin/bash")
                                                   flags))))
        (error (display-warning 'my-shell-path (error-message-string err)))))
    (let ((path (mapconcat #'identity
                           (delete-dups
                            (apply #'append
                                   (mapcar (lambda (value) (split-string value path-separator))
                                           paths)))
                           path-separator)))
      (setq exec-path (append (parse-colon-path path) (list exec-directory)))
      (setenv "PATH" path))))

(provide 'my-shell-path)
