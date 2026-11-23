;;; protobuf-tests.el --- Protobuf server scope and launch checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../protobuf.el" (file-name-directory load-file-name)) nil t)

(ert-deftest my-protobuf-launches-discovery-without-reading-generate ()
  (let* ((root (file-name-as-directory (make-temp-file "proto-launch-" t)))
         (buffer-file-name (expand-file-name "api/a.proto" root)))
    (unwind-protect
        (let ((command (my-protobuf-eglot-contact nil (cons 'transient root))))
          (should (equal (car command) "python3"))
          (should (file-readable-p (cadr command)))
          (should (equal (cddr command) (list root buffer-file-name)))
          (should-not (file-exists-p (expand-file-name "buf.yaml" root))))
      (delete-directory root t))))

(ert-deftest my-protobuf-components-use-independent-lsp-projects ()
  (let* ((root (file-name-as-directory (make-temp-file "proto-scope-" t)))
         (project-find-functions
          (list #'my-protobuf-project-find (lambda (_) (cons 'transient root))))
         (eglot-lsp-context t)
         (major-mode 'protobuf-mode)
         first second)
    (unwind-protect
        (progn
          (dolist (name '("a" "b")) (make-directory (expand-file-name name root)))
          (let ((buffer-file-name (expand-file-name "a/schema.proto" root)))
            (setq first (my-protobuf-project-find (file-name-directory buffer-file-name))))
          (let ((buffer-file-name (expand-file-name "b/schema.proto" root)))
            (setq second (my-protobuf-project-find (file-name-directory buffer-file-name))))
          (should-not (equal first second))
          (should (equal (project-root first) (file-truename root)))
          (should (equal (project-root first) (project-root second)))
          (let ((eglot-lsp-context nil))
            (should-not (my-protobuf-project-find root))))
      (delete-directory root t))))

(ert-deftest my-protobuf-keeps-existing-buf-configuration ()
  (let* ((root (file-name-as-directory (make-temp-file "proto-native-" t)))
         (buffer-file-name (expand-file-name "a.proto" root))
         (eglot-lsp-context t)
         (major-mode 'protobuf-mode))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "buf.yaml" root) (insert "version: v2\n"))
          (should-not (my-protobuf-project-find root))
          (should (equal (my-protobuf-eglot-contact nil (cons 'transient root))
                         '("buf" "lsp" "serve"))))
      (delete-directory root t))))
