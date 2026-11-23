;;; protobuf.el --- Automatic Protobuf import discovery -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'project)
(require 'eglot)

(defconst my-protobuf-server-script
  (expand-file-name "tools/protobuf-lsp.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun my-protobuf-project-find (directory)
  "Give each schema directory its own LSP context within the real project.
Different components may import different files under the same Protobuf name."
  (when (and eglot-lsp-context (derived-mode-p 'protobuf-mode)
             buffer-file-name (not (file-remote-p directory))
             (not (locate-dominating-file directory "buf.yaml")))
    (let* ((project-find-functions (remq #'my-protobuf-project-find project-find-functions))
           (project (project-current nil directory)))
      (list 'my-protobuf
            (file-name-as-directory (file-truename (if project (project-root project) directory)))
            (file-name-as-directory (file-truename directory))))))

(cl-defmethod project-root ((project (head my-protobuf)))
  (nth 1 project))

(cl-defmethod project-name ((project (head my-protobuf)))
  (concat (file-name-nondirectory (directory-file-name (project-root project)))
          ":" (file-relative-name (nth 2 project) (project-root project))))

(defun my-protobuf-eglot-contact (_interactive project)
  "Discover imports outside Emacs, then start Buf without project config files."
  (if (or (not buffer-file-name) (file-remote-p buffer-file-name)
          (locate-dominating-file (file-name-directory buffer-file-name) "buf.yaml"))
      '("buf" "lsp" "serve")
    (list "python3" my-protobuf-server-script (project-root project) buffer-file-name)))

(defun my-protobuf-eglot-setup ()
  "Keep referenced dependency files attached to their originating server."
  (setq-local eglot-extend-to-xref t)
  (eglot-ensure))

(add-hook 'project-find-functions #'my-protobuf-project-find)

(provide 'my-protobuf)
