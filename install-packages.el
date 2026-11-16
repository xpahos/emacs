;;; install-packages.el --- Install project UI dependencies -*- lexical-binding: t; -*-

(require 'package)
(setq package-user-dir (expand-file-name "elpa" (file-name-directory load-file-name))
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(package-refresh-contents)
(dolist (package '(treemacs treemacs-tab-bar tabspaces dashboard magit diff-hl))
  (unless (package-installed-p package)
    (package-install package)))
