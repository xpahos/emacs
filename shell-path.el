;;; shell-path.el --- Import paths and certificates from the login shell -*- lexical-binding: t; -*-

(defun my-shell-environment (shell flags)
  "Return (PATH NODE_EXTRA_CA_CERTS) from SHELL with FLAGS within five seconds."
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
                                  "printf '\\000EMACS_ENV\\000%s\\000%s\\000' \"$PATH\" \"${NODE_EXTRA_CA_CERTS-}\"")
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
            (unless (re-search-forward "\0EMACS_ENV\0\\([^\0]+\\)\0\\([^\0]*\\)\0" nil t)
              (error "Shell did not return a nonempty PATH"))
            (list (match-string-no-properties 1) (match-string-no-properties 2)))
        (when (and process (process-live-p process))
          (delete-process process))))))

(defun my-import-shell-path ()
  "Import PATH and NODE_EXTRA_CA_CERTS, adding missing paths from Bash."
  (interactive)
  (let* ((shell (or (getenv "SHELL") shell-file-name))
         (bash-primary (equal (file-name-nondirectory shell) "bash"))
         (environment
          (let ((process-environment (copy-sequence process-environment)))
            ;; Let shell defaults replace stale values inherited by a GUI launcher.
            (setenv "NODE_EXTRA_CA_CERTS" nil)
            (my-shell-environment shell "-lic")))
         (paths (list (car environment))))
    ;; A separate non-login Bash reads .bashrc even if its profile does not.
    (dolist (flags (if bash-primary '("-ic") '("-lic" "-ic")))
      (condition-case err
          (setq paths (append paths
                              (list (car (my-shell-environment
                                          (if bash-primary shell "/bin/bash") flags)))))
        (error (display-warning 'my-shell-path (error-message-string err)))))
    (let ((path (mapconcat #'identity
                           (delete-dups
                            (apply #'append
                                   (mapcar (lambda (value) (split-string value path-separator))
                                           paths)))
                           path-separator)))
      (setq exec-path (append (parse-colon-path path) (list exec-directory)))
      (setenv "PATH" path)
      ;; Bash supplements executable paths, but the primary shell owns certificates.
      (setenv "NODE_EXTRA_CA_CERTS"
              (unless (equal (cadr environment) "") (cadr environment))))))

(provide 'my-shell-path)
