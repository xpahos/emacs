;;; shell-path-tests.el --- Shell PATH import checks -*- lexical-binding: t; -*-
(require 'ert)
(load (expand-file-name "../shell-path.el" (file-name-directory load-file-name)) t t)

(ert-deftest my-pi-certificates-follow-shell-environment-on-reload ()
  (require 'package)
  (let* ((root (file-name-directory (symbol-file 'my-import-shell-path)))
         (package-user-dir (expand-file-name "elpa" root))
         (user-emacs-directory (make-temp-file "pi-ca-env-" t))
         (process-environment (copy-sequence process-environment))
         (bundle (expand-file-name "custom CA.pem" user-emacs-directory)))
    (package-initialize)
    (require 'agent-shell-pi)
    (let ((agent-shell-pi-environment '("SSL_CERT_FILE=/old.pem" "KEEP=value")))
      (unwind-protect
          (progn
            (with-temp-file bundle (insert "test fixture\n"))
            (setenv "NODE_EXTRA_CA_CERTS" bundle)
            (dotimes (_ 2)
              (load (expand-file-name "pi-panel.el" root) nil t))
            (should (= (length agent-shell-pi-environment) 4))
            (should (member "KEEP=value" agent-shell-pi-environment))
            (let ((process-environment (append agent-shell-pi-environment process-environment)))
              (with-temp-buffer
                (should (zerop (call-process
                                "/bin/sh" nil t nil "-c"
                                "test \"$SSL_CERT_FILE\" = \"$NODE_EXTRA_CA_CERTS\" && test \"$REQUESTS_CA_BUNDLE\" = \"$NODE_EXTRA_CA_CERTS\" && test -r \"$SSL_CERT_FILE\"")))))
            (setenv "NODE_EXTRA_CA_CERTS" nil)
            (load (expand-file-name "pi-panel.el" root) nil t)
            (should (equal agent-shell-pi-environment '("KEEP=value"))))
        (delete-directory user-emacs-directory t)))))

(ert-deftest my-shell-path-merges-bash-after-zsh-and-ignores-noise ()
  (let ((directory (make-temp-file "emacs-shell-path-" t))
        (process-environment (copy-sequence process-environment))
        (exec-path '("/old/path")))
    (unwind-protect
        (progn
          (setenv "SHELL" "/bin/zsh")
          (setenv "ZDOTDIR" directory)
          (setenv "HOME" directory)
          (setenv "NODE_EXTRA_CA_CERTS" "/stale/launcher-ca.pem")
          (with-temp-file (expand-file-name ".zshenv" directory)
            (insert "unsetopt GLOBAL_RCS\nexport PATH=/from/env\n"
                    "export NODE_EXTRA_CA_CERTS=\"${NODE_EXTRA_CA_CERTS:-$HOME/custom CA.pem}\"\n"))
          (with-temp-file (expand-file-name ".zprofile" directory)
            (insert "export PATH=\"$PATH:/from/profile\"\n"))
          (with-temp-file (expand-file-name ".zshrc" directory)
            (insert "printf 'terminal noise\\n'\nexport PATH=\"$PATH:/from/rc with spaces\"\n"))
          (with-temp-file (expand-file-name ".bash_profile" directory)
            (insert "export PATH=/from/bash:/from/env\n"))
          (with-temp-file (expand-file-name ".bashrc" directory)
            (insert "export PATH=/from/bashrc:/from/env\nprintf 'bash noise\\n'\n"
                    "export NODE_EXTRA_CA_CERTS=/wrong/bash-ca.pem\n"))
          (my-import-shell-path)
          (should (equal (getenv "NODE_EXTRA_CA_CERTS")
                         (expand-file-name "custom CA.pem" directory)))
          (should (equal (getenv "PATH")
                         "/from/env:/from/profile:/from/rc with spaces:/from/bash:/from/bashrc"))
          (should (equal exec-path
                         (list "/from/env/" "/from/profile/" "/from/rc with spaces/"
                               "/from/bash/" "/from/bashrc/" exec-directory)))
          ;; A broken optional rc file must not discard the working shell PATH.
          (with-temp-file (expand-file-name ".bashrc" directory) (insert "exit 1\n"))
          (setenv "NODE_EXTRA_CA_CERTS" "/inherited/override.pem")
          (my-import-shell-path)
          (should (equal (getenv "NODE_EXTRA_CA_CERTS")
                         (expand-file-name "custom CA.pem" directory)))
          (should (equal (getenv "PATH")
                         "/from/env:/from/profile:/from/rc with spaces:/from/bash")))
      (delete-directory directory t))))

(ert-deftest my-shell-path-bash-login-precedence-and-rc ()
  (let ((directory (make-temp-file "emacs-bash-path-" t))
        (process-environment (copy-sequence process-environment))
        (exec-path exec-path))
    (unwind-protect
        (progn
          (setenv "SHELL" "/bin/bash")
          (setenv "HOME" directory)
          (with-temp-file (expand-file-name ".profile" directory)
            (insert "export PATH=/from/profile\n"))
          (with-temp-file (expand-file-name ".bash_login" directory)
            (insert "export PATH=/from/login\n"))
          (with-temp-file (expand-file-name ".bash_profile" directory)
            (insert "export PATH=/from/bash-profile\n. ~/.bashrc\n"))
          (with-temp-file (expand-file-name ".bashrc" directory)
            (insert "export PATH=\"/from/rc:$PATH\"\n"))
          (dolist (expected '("/from/rc:/from/bash-profile" "/from/login:/from/rc"
                              "/from/profile:/from/rc"))
            (setenv "PATH" "/from/rc")
            (my-import-shell-path)
            (should (equal (getenv "PATH") expected))
            (let ((profile (expand-file-name
                            (if (file-exists-p (expand-file-name ".bash_profile" directory))
                                ".bash_profile" ".bash_login") directory)))
              (when (file-exists-p profile) (delete-file profile)))))
      (delete-directory directory t))))

(ert-deftest my-shell-path-preserves-environment-on-failure ()
  (let ((shell (make-temp-file "emacs-broken-shell-"))
        (process-environment (copy-sequence process-environment))
        (exec-path '("/old/path")))
    (unwind-protect
        (progn
          (setenv "SHELL" shell)
          (setenv "PATH" "/old/path")
          (setenv "NODE_EXTRA_CA_CERTS" "/existing/cert.pem")
          (set-file-modes shell #o700)
          (dolist (body '("exit 1" "printf 'unexpected output'" "exec /bin/sleep 10"))
            (with-temp-file shell (insert "#!/bin/sh\n" body "\n"))
            (should-error (my-import-shell-path))
            (should (equal (getenv "PATH") "/old/path"))
            (should (equal (getenv "NODE_EXTRA_CA_CERTS") "/existing/cert.pem"))
            (should (equal exec-path '("/old/path")))))
      (delete-file shell))))
