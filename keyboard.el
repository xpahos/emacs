;;; keyboard.el --- Layout-independent modified keys -*- lexical-binding: t; -*-

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
