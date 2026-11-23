;;; protobuf-smoke.el --- Real Protobuf navigation without build scripts -*- lexical-binding: t; -*-
;; Needs python3 and buf with `lsp serve' on PATH.
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(let* ((root (file-name-as-directory (file-truename (make-temp-file "emacs-proto-" t))))
       (project--list nil)
       (process-environment (copy-sequence process-environment))
       (eglot-connect-timeout 15)
       files servers)
  (setenv "XDG_CACHE_HOME" (expand-file-name "cache" root))
  (unwind-protect
      (progn
        ;; Two components deliberately use incompatible definitions of the same type.
        (dolist (component '("one" "two"))
          (let ((types (expand-file-name (concat component "/deps/acme/types.proto") root))
                (usage (expand-file-name (concat component "/api/usage.proto") root)))
            (make-directory (file-name-directory types) t)
            (make-directory (file-name-directory usage) t)
            (with-temp-file types
              (insert "syntax = \"proto3\";\npackage example;\nmessage User { string "
                      component " = 1; }\n"))
            (with-temp-file usage
              (insert "syntax = \"proto3\";\npackage example;\nimport \"acme/types.proto\";\n"
                      "message Request { User user = 1; }\n"))
            (push (cons usage types) files)))
        (project-remember-project (cons 'transient root))
        (dolist (pair files)
          (find-file (car pair))
          (cl-assert (eq major-mode 'protobuf-mode))
          (font-lock-ensure)
          (goto-char (point-min))
          (search-forward "message")
          (cl-assert (eq (get-text-property (1- (point)) 'face) 'font-lock-keyword-face))
          (cl-assert (null eglot-sync-connect))
          (run-hooks 'post-command-hook)
          (let ((deadline (+ (float-time) 15)))
            (while (and (not (eglot-managed-p)) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (cl-assert (eglot-current-server))
          (cl-assert (not (memq (eglot-current-server) servers)))
          (push (eglot-current-server) servers)
          (search-forward "User")
          (backward-char 2)
          (let ((definitions (xref-backend-definitions
                              'eglot (xref-backend-identifier-at-point 'eglot)))
                (references (xref-backend-references
                             'eglot (xref-backend-identifier-at-point 'eglot))))
            (cl-assert (= (length definitions) 1))
            (cl-assert (equal (file-truename
                              (xref-file-location-file (xref-item-location (car definitions))))
                             (cdr pair)))
            (cl-assert (seq-some
                        (lambda (ref)
                          (equal (file-truename (xref-file-location-file (xref-item-location ref)))
                                 (car pair)))
                        references))
            (with-current-buffer (marker-buffer (xref-location-marker (xref-item-location (car definitions))))
              (run-hooks 'post-command-hook)
              (cl-assert (eq (eglot-current-server) (car servers))))))
        (cl-assert (not (file-exists-p (expand-file-name "buf.yaml" root))))
        (princ "Protobuf: highlighting, automatic imports, two independent components, definitions and references passed without generate or buf.yaml.\n"))
    (dolist (server servers) (when (jsonrpc-running-p server) (eglot-shutdown server)))
    (dolist (pair files)
      (dolist (file (list (car pair) (cdr pair)))
        (when-let* ((buffer (get-file-buffer file))) (kill-buffer buffer))))
    (delete-directory root t)))
