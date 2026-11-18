;;; popup-style.el --- Shared appearance for floating help -*- lexical-binding: t; -*-

(require 'posframe)

(set-face-attribute 'child-frame-border nil :background "#73726b")

(defun my-popup-frame-parameters ()
  "Return the common colors, border and padding for floating help."
  `((background-color . ,(face-background 'tooltip nil t))
    (foreground-color . ,(face-foreground 'tooltip nil t))
    (internal-border-width . 2) (child-frame-border-width . 2)
    (left-fringe . 12) (right-fringe . 12)
    (tab-bar-lines . 0) (tab-bar-lines-keep-state . t)))

(defun my-popup-show (buffer text window position)
  "Show TEXT in BUFFER beside WINDOW at parent-frame pixel POSITION."
  (add-face-text-property 0 (length text) 'tooltip t text)
  (with-selected-window window
    (let ((posframe-mouse-banish-function #'ignore))
      (posframe-show buffer :string text :position position
                     :max-width 80 :max-height 30
                     :override-parameters (my-popup-frame-parameters)))))

(provide 'my-popup-style)
;;; popup-style.el ends here
