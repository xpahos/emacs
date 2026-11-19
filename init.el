;;; init.el --- Emacs configuration -*- lexical-binding: t; -*-

(tool-bar-mode -1)

;; Work around the macOS 31.1 ns_judge_scroll_bars / CALayerArray abort.
(when (eq system-type 'darwin)
  (scroll-bar-mode -1)
  (horizontal-scroll-bar-mode -1))

;; Use the bundled Modus theme with a muted, paper-like palette.
(require-theme 'modus-themes)
(setq modus-themes-bold-constructs nil
      modus-themes-italic-constructs nil
      modus-operandi-palette-overrides
      (append
       ;; GoLand Dark syntax roles, darkened and muted for stone paper.
       '((comment "#3c3f39")
         (builtin "#482818")
         (constant "#24534e")
         (docstring "#1d361c")
         (fnname "#14334f")
         (fnname-call "#402e18")
         (keyword "#482818")
         (preprocessor "#482818")
         (property "#24534e")
         (string "#1d361c")
         (type "#153538")
         (number "#0f353b")
         (variable "#29313d")
         (variable-use "#29313d")
         (accent-0 "#24534e")
         (fg-completion-match-0 "#102034")
         (fg-completion-match-1 "#102034")
         (fg-completion-match-2 "#102034")
         (fg-completion-match-3 "#102034")
         (fg-link blue)
         (underline-link blue)
         (fg-link-visited magenta)
         (bg-completion bg-active)
         (bg-hover bg-active)
         (bg-hl-line bg-dim))
       (modus-themes-generate-palette
        '((bg-main "#999891")
          (bg-dim "#898880")
          (bg-active "#898880")
          (bg-inactive "#898880")
          (border "#73726b")
          (fg-main "#20211e")
          (fg-dim "#2d3028")
          (fg-alt "#2d2a25")
          (red "#632025")
          (green "#19380f")
          (yellow "#4f2c0e")
          (blue "#173568")
          (magenta "#24534e")
          (cyan "#083b3a")))))
(mapc #'disable-theme custom-enabled-themes)
(load-theme 'modus-operandi t)

;; Apply after the theme, which resets face attributes when reloaded.
(set-face-attribute 'default nil :family "JetBrains Mono NL" :height 140
                    :weight 'semi-bold)
(set-face-attribute 'fixed-pitch nil :family "JetBrains Mono NL"
                    :weight 'semi-bold)

;; Cursor-line and text selection keep their distinct background.
(dolist (face '(region hl-line treemacs-hl-line-face))
  (custom-set-faces
   `(,face ((t (:background "#1c4642" :foreground "#dbe5df"))))))
(dolist (face '(highlight modus-themes-completion-selected
                header-line header-line-active header-line-inactive
                mode-line mode-line-active mode-line-inactive my-wt-header-frame))
  (custom-set-faces
   `(,face ((t (:background "#898880" :foreground "#20211e"))))))

(require 'package)
(let ((config-directory (file-name-directory (or load-file-name buffer-file-name))))
  (setq package-user-dir (expand-file-name "elpa" config-directory))
  (package-initialize)
  (load (expand-file-name "popup-style.el" config-directory) nil t)
  (load (expand-file-name "keyboard.el" config-directory) nil t)
  (load (expand-file-name "projects.el" config-directory) nil t)
  (load (expand-file-name "navigation.el" config-directory) nil t)
  (load (expand-file-name "arcadia.el" config-directory) nil t)
  (load (expand-file-name "project-search.el" config-directory) nil t)
  (load (expand-file-name "overview.el" config-directory) nil t)
  (load (expand-file-name "modified-state.el" config-directory) nil t)
  (load (expand-file-name "markdown-view.el" config-directory) nil t)
  (load (expand-file-name "pi-panel.el" config-directory) nil t)
  (load (expand-file-name "agent-completion.el" config-directory) nil t)
  (load (expand-file-name "terminal.el" config-directory) nil t))

;; Separate edges leave the current tab open at the bottom.
(dolist (face '(tab-bar tab-line tab-line-active tab-line-inactive
                tab-bar-tab tab-bar-tab-inactive tab-line-tab
                tab-line-tab-current tab-line-tab-inactive
                tab-line-tab-inactive-alternate))
  (let ((tab (memq face '(tab-bar-tab tab-bar-tab-inactive tab-line-tab
                         tab-line-tab-current tab-line-tab-inactive
                         tab-line-tab-inactive-alternate)))
        (current (memq face '(tab-bar-tab tab-line-tab tab-line-tab-current))))
    (custom-set-faces
     `(,face ((t (:background "#898880" :foreground "#20211e" :box nil
                  :overline ,(and tab "#73726b")
                  :underline ,(unless current
                                '(:color "#73726b" :position t)))))))))
(dolist (face '(tab-bar-tab-highlight tab-line-highlight))
  (set-face-attribute face nil :box nil :overline 'unspecified
                      :underline 'unspecified))

(defun my-tab-side-edges (label)
  "Pad LABEL inside thin side edges while retaining its mouse actions."
  (let ((padding (apply #'propertize " " (text-properties-at 0 label)))
        (edge (propertize " "
                          'display '(space :width (1))
                          'face '(:background "#73726b" :box nil
                                  :overline nil :underline nil)
                          'mouse-face '(:background "#73726b"))))
    (add-text-properties 0 1
                         (list 'tab (get-text-property 0 'tab label)
                               'selected (get-text-property 0 'selected label)
                               'keymap (get-text-property 0 'keymap label))
                         edge)
    (put-text-property 0 1 'display
                       '(space :width (10) :height 1.3 :ascent 75) padding)
    (concat edge padding label padding edge)))

(defun my-tab-bar-label (tab index)
  "Format a project TAB at INDEX with side edges."
  (my-tab-side-edges (tab-bar-tab-name-format-default tab index)))

(defun my-tab-line-label (tab tabs)
  "Format a file TAB among TABS with side edges and its full path as help."
  (let ((label (tab-line-tab-name-format-default tab tabs)))
    (when (and (bufferp tab) (buffer-file-name tab))
      (put-text-property 0 (next-single-property-change
                            0 'help-echo label (length label))
                         'help-echo (buffer-file-name tab) label))
    (my-tab-side-edges label)))

(defun my-tab-line-fill (items)
  "Continue the lower border after tab ITEMS to the window edge."
  (append items (list (propertize " " 'display '(space :align-to right)
                                 'face 'tab-line))))

;; Auto-padding copies the one-pixel edge and can loop without gaining width.
(setq tab-bar-auto-width nil
      tab-bar-tab-name-format-function #'my-tab-bar-label
      tab-line-tab-name-format-function #'my-tab-line-label
      tab-bar-format '(tab-bar-format-tabs tab-bar-separator
                      tab-bar-format-align-right))
(advice-add 'tab-line-format-template :filter-return #'my-tab-line-fill)
(tab-line-force-update t)
(force-mode-line-update t)
