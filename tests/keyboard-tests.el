;;; keyboard-tests.el --- Modified keys across keyboard layouts -*- lexical-binding: t; -*-
(require 'ert)
(load (expand-file-name "../keyboard.el" (file-name-directory load-file-name)) nil t)

(defun my-keyboard-test-read (keys)
  (let ((unread-command-events (append (kbd keys) nil)))
    (read-key-sequence-vector "")))

(ert-deftest my-keyboard-russian-shortcuts-preserve-modifiers ()
  (dolist (pair '(("s-с" . "s-c") ("s-м" . "s-v") ("s-С" . "s-C")
                  ("M-ч" . "M-x") ("C-ч C-ы" . "C-x C-s")
                  ("C-M-а" . "C-M-f") ("s-х" . "s-[") ("s-Х" . "s-{")))
    (should (equal (my-keyboard-test-read (car pair)) (vconcat (kbd (cdr pair)))))))

(ert-deftest my-keyboard-plain-russian-and-english-are-unchanged ()
  (dolist (key '("с" "м" "Я" "ё" "s-c" "s-v" "M-x"))
    (should (equal (my-keyboard-test-read key) (vconcat (kbd key))))))

(ert-deftest my-keyboard-translations-use-local-bindings ()
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (local-set-key (kbd "s-c") #'copy-region-as-kill)
    (local-set-key (kbd "s-v") #'yank)
    (should (eq (key-binding (my-keyboard-test-read "s-с")) #'copy-region-as-kill))
    (should (eq (key-binding (my-keyboard-test-read "s-м")) #'yank))))
