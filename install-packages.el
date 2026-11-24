;;; install-packages.el --- Install project UI dependencies -*- lexical-binding: t; -*-

(require 'package)
(setq package-user-dir (expand-file-name "elpa" (file-name-directory load-file-name))
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(package-refresh-contents)
(dolist (package '(treemacs treemacs-tab-bar tabspaces dashboard magit diff-hl ghostel posframe corfu protobuf-mode kotlin-mode))
  (unless (package-installed-p package)
    (package-install package)))

(require 'markdown-ts-mode)
(let ((grammar-directory
       (expand-file-name "tree-sitter" (file-name-directory load-file-name))))
  (add-to-list 'treesit-extra-load-path grammar-directory)
  (dolist (language '(markdown markdown-inline))
    (unless (treesit-language-available-p language)
      (treesit-install-language-grammar language grammar-directory))
    (unless (treesit-language-available-p language)
      (error "Markdown grammar installation failed: %s" language))))
