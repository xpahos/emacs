;;; keyboard.el --- Editing defaults and layout-independent keys -*- lexical-binding: t; -*-

(setq-default indent-tabs-mode nil
              tab-width 4
              standard-indent 4
              c-basic-offset 4
              c-ts-indent-offset 4
              go-ts-indent-offset 4
              rust-ts-indent-offset 4
              python-indent-offset 4
              python-indent-guess-indent-offset nil
              js-indent-level 4
              typescript-ts-indent-offset 4)

(defun my-editing-shift-line (columns)
  "Shift the current line by COLUMNS; keep normal indentation for a region."
  (if (use-region-p)
      (call-interactively #'indent-for-tab-command)
    (let ((target (max 0 (+ (current-indentation) columns))))
      (if (<= (current-column) (current-indentation))
          (indent-line-to target)
        (save-excursion (indent-line-to target))))))

(defun my-editing-tab ()
  "Increase the current line's indentation by one displayed tab."
  (interactive)
  (my-editing-shift-line tab-width))

(defun my-editing-backtab ()
  "Decrease the current line's indentation by one displayed tab."
  (interactive)
  (my-editing-shift-line (- tab-width)))

(define-minor-mode my-editing-indent-mode
  "Shift individual file lines with Tab and Shift-Tab."
  :lighter nil
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "TAB") #'my-editing-tab)
            (define-key map [tab] #'my-editing-tab)
            (define-key map [backtab] #'my-editing-backtab)
            (define-key map [S-tab] #'my-editing-backtab)
            map))

(defun my-editing-indent-setup ()
  "Use four-column indentation, retaining tabs for Go and Makefiles."
  (when (derived-mode-p 'prog-mode 'text-mode 'conf-mode)
    (setq-local tab-width 4
                indent-tabs-mode
                (and (derived-mode-p 'go-mode 'go-ts-mode 'go-mod-ts-mode
                                     'go-work-ts-mode 'makefile-mode) t))
    (my-editing-indent-mode (if buffer-file-name 1 -1))))

;; Apply after mode bodies have installed their own indentation settings.
(add-hook 'after-change-major-mode-hook #'my-editing-indent-setup)

;; Russian PC and U.S. keys at the same physical positions.  Plain typing
;; stays untouched; translation preserves the active mode's English bindings.
(let ((russian "йцукенгшщзхъфывапролджэячсмитьбюёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮЁ")
      (english "qwertyuiop[]asdfghjkl;'zxcvbnm,.`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>~"))
  (dolist (modifiers '((super) (control) (meta) (control meta)
                       (control super) (meta super) (control meta super)))
    (dotimes (i (length russian))
      (define-key key-translation-map
                  (vector (event-convert-list (append modifiers (list (aref russian i)))))
                  (vector (event-convert-list (append modifiers (list (aref english i)))))))))

(provide 'my-keyboard)
