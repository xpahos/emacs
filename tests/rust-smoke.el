;;; rust-smoke.el --- Real Rust navigation in libtpms-rs-compat -*- lexical-binding: t; -*-
;; Needs a libtpms-rs-compat checkout named by EMACS_TEST_RUST_ROOT (see README "Tests").
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(defun my-test-rust-root ()
  "Return the checkout named by EMACS_TEST_RUST_ROOT, or signal why it is unusable."
  (let ((value (getenv "EMACS_TEST_RUST_ROOT")))
    (when (or (null value) (string-empty-p value))
      (error "EMACS_TEST_RUST_ROOT is not set; point it at a libtpms-rs-compat checkout"))
    ;; Truename: rust-analyzer reports resolved paths, which symlinked roots would not match.
    (let ((root (file-name-as-directory (file-truename (expand-file-name value)))))
      (unless (file-directory-p root)
        (error "EMACS_TEST_RUST_ROOT is not a directory: %s" root))
      (dolist (fixture '("Cargo.toml" "src/ffi/api.rs" "src/version.rs"))
        (unless (file-regular-p (expand-file-name fixture root))
          (error "EMACS_TEST_RUST_ROOT %s is not a libtpms-rs-compat checkout: missing %s"
                 root fixture)))
      root)))
(let* ((root (my-test-rust-root))
       (file (expand-file-name "src/ffi/api.rs" root))
       (target (make-temp-file "emacs-rust-target-" t))
       (eglot-connect-timeout 20)
       (project--list nil)
       (process-environment (copy-sequence process-environment)))
  (setenv "CARGO_TARGET_DIR" target)
  (setenv "CARGO_NET_OFFLINE" "true")
  (unwind-protect
      (progn
        (my-project-open root)
        (find-file file)
        (cl-assert (eq major-mode 'rust-ts-mode))
        (cl-assert (null eglot-sync-connect))
        (run-hooks 'post-command-hook)
        (let ((deadline (+ (float-time) 20)))
          (while (and (not (eglot-managed-p)) (< (float-time) deadline))
            (accept-process-output nil 0.05)))
        (cl-assert (eglot-current-server))
        (cl-assert (equal (file-truename (project-root (eglot--project (eglot-current-server))))
                          (file-truename root)))
        (goto-char (point-min))
        (search-forward "crate::version::TPM_LIBRARY_VERSION")
        (backward-char 3)
        (let ((deadline (+ (float-time) 45)) definitions last-error)
          (while (and (not definitions) (< (float-time) deadline))
            (condition-case err
                (setq definitions
                      (xref-backend-definitions 'eglot
                                               (xref-backend-identifier-at-point 'eglot)))
              (error (setq last-error err)))
            (unless definitions (accept-process-output nil 0.2)))
          (unless definitions (error "No Rust definition: %S" last-error))
          (cl-assert (equal (file-truename
                             (xref-file-location-file (xref-item-location (car definitions))))
                            (file-truename (expand-file-name "src/version.rs" root)))))
        (let ((references (xref-backend-references
                           'eglot (xref-backend-identifier-at-point 'eglot))))
          (cl-assert (>= (length references) 2))
          (cl-assert (seq-some
                      (lambda (ref)
                        (equal (xref-file-location-file (xref-item-location ref)) file))
                      references)))
        (princ "Rust mode and rust-analyzer connected; definition and references resolved across libtpms files.\n")
        (princ (format "Temporary Cargo build directory: %s\n" target)))
    (when-let* ((buffer (get-file-buffer file)))
      (with-current-buffer buffer
        (when-let* ((server (eglot-current-server))) (eglot-shutdown server)))
      (kill-buffer buffer))))
