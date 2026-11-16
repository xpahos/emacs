;;; go-colors-tests.el --- Go syntax colour coverage -*- lexical-binding: t; -*-
(require 'ert)
(setq user-emacs-directory (make-temp-file "emacs-go-colors-" t))
(load (expand-file-name "../init.el" (file-name-directory load-file-name)) nil t)
(require 'go-ts-mode)

(ert-deftest my-go-colors-cover-declarations-and-uses ()
  (with-temp-buffer
    (insert "package demo
// A sample.
type Record struct { Title string }
const Limit = 42
func Render(input Record) string {
    result := input.Title
    println(result)
    return result + \"text\"
}
func main() { Render(Record{Title: \"hello\"}) }
")
    (let ((go-ts-mode-hook (remove #'eglot-ensure go-ts-mode-hook)))
      (go-ts-mode))
    (font-lock-ensure)
    (dolist (sample '(("// A sample" . font-lock-comment-face)
                      ("type" . font-lock-keyword-face)
                      ("Record struct" . font-lock-type-face)
                      ("Title string" . font-lock-property-name-face)
                      ("Limit" . font-lock-constant-face)
                      ("42" . font-lock-number-face)
                      ("Render(input" . font-lock-function-name-face)
                      ("input Record" . font-lock-variable-name-face)
                      ("result :=" . font-lock-variable-name-face)
                      ("input.Title" . font-lock-variable-use-face)
                      ("Title\n" . font-lock-property-use-face)
                      ("println" . font-lock-builtin-face)
                      ("result)" . font-lock-variable-use-face)
                      ("\"text\"" . font-lock-string-face)
                      ("Render(Record" . font-lock-function-call-face)))
      (goto-char (point-min))
      (search-forward (car sample))
      (let ((face (get-text-property (match-beginning 0) 'face)))
        (should (memq (cdr sample) (if (listp face) face (list face))))))))
