;;; agent-completion-tests.el --- Completion lifecycle checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'package)
(setq package-user-dir (expand-file-name "../elpa" (file-name-directory load-file-name)))
(package-initialize)
(load (expand-file-name "../project-search.el" (file-name-directory load-file-name)) nil t)
(load (expand-file-name "../agent-completion.el" (file-name-directory load-file-name)) nil t)

(ert-deftest my-agent-completion-survives-output-before-prompt ()
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (setq major-mode 'agent-shell-mode)
      (corfu-mode 1)
      (insert "Output\nPi> /")
      (let ((completion-in-region-mode-predicate #'always)
            (this-command 'corfu-next))
        (unwind-protect
            (progn
              (corfu--setup (point) (point) '("one" "two") nil)
              (save-excursion (goto-char (point-min)) (insert "New output\n"))
              (should (corfu--continue-p))
              (should (= (car completion-in-region--data) (point)))
              (insert "o")
              (should (equal (buffer-substring-no-properties
                              (car completion-in-region--data) (point)) "o"))
              (delete-char -1)
              (should (corfu--continue-p))
              (delete-char -1)
              (should-not (corfu--continue-p)))
          (corfu-quit))))))

(ert-deftest my-agent-selected-row-overrides-dark-match-colors ()
  (let* ((match (propertize "review" 'face 'completions-common-part))
         (lines (list match "reload")))
    (my-agent-completion-selected-row nil nil nil lines 0)
    (should (eq (car (get-text-property 0 'face (car lines))) 'corfu-current))
    (should (eq (get-text-property 0 'face match) 'completions-common-part))
    (should-not (get-text-property 0 'face (cadr lines)))
    (my-agent-completion-selected-row nil nil nil lines -1)
    (my-agent-completion-selected-row nil nil nil lines nil)))

(ert-deftest my-agent-files-stream-before-scan-finishes ()
  (with-temp-buffer
    (setq major-mode 'agent-shell-mode)
    (corfu-mode 1)
    (insert "@")
    (cl-letf (((symbol-function 'my-project-search-source)
               (lambda (root)
                 (list root "sh" "-c"
                       "printf 'first file.txt\\0'; sleep 1; printf 'later.txt\\0'")))
              ((symbol-function 'agent-shell--project-files)
               (lambda () (ert-fail "Synchronous project scan"))))
      (unwind-protect
          (let* ((start (float-time))
                 (capf (agent-shell--file-completion-at-point))
                 (table (nth 2 capf)))
            (should (< (- (float-time) start) 0.2))
            (should-not (all-completions "" table))
            (let ((deadline (+ (float-time) 0.7)))
              (while (and (not (all-completions "" table)) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should (equal (all-completions "" table) '("first file.txt")))
            (let ((deadline (+ (float-time) 2)))
              (while (and (not (all-completions "later" table)) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should (equal (all-completions "later" table) '("later.txt")))
            (should (equal (all-completions "" table) '("first file.txt" "later.txt"))))
        (when (fboundp 'my-agent-files-stop) (my-agent-files-stop))))))

(ert-deftest my-agent-files-cancel-stops-indexing ()
  (with-temp-buffer
    (setq major-mode 'agent-shell-viewport-edit-mode)
    (corfu-mode 1)
    (insert "@")
    (cl-letf (((symbol-function 'my-project-search-source)
               (lambda (root) (list root "sleep" "30"))))
      (let* ((before (process-list))
             (_capf (agent-shell--file-completion-at-point))
             (new (seq-difference (process-list) before)))
        (unwind-protect
            (progn
              (should (seq-some #'process-live-p new))
              (run-hooks 'completion-in-region-mode-hook)
              (should-not (seq-some #'process-live-p new))
              (should-not my-agent-file-table))
          (mapc (lambda (p) (when (process-live-p p) (delete-process p))) new))))))

(ert-deftest my-agent-files-leaves-other-completion-alone ()
  (with-temp-buffer
    (insert "@")
    (cl-letf (((symbol-function 'agent-shell--project-files)
               (lambda () '("original.txt"))))
      (should (equal (nth 2 (agent-shell--file-completion-at-point)) '("original.txt"))))))
