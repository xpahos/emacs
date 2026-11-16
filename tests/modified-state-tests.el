;;; modified-state-tests.el --- Check automatic clean-buffer detection -*- lexical-binding: t; -*-
(require 'ert)
(load "/Volumes/Sources/emacs/modified-state.el" nil t)

(defmacro my-modified-test-file (bytes &rest body)
  (declare (indent 1))
  `(let ((file (make-temp-file "emacs-modified-")) buffer)
     (unwind-protect
         (progn
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert ,bytes)
             (let ((coding-system-for-write 'no-conversion)) (write-region nil nil file nil 'silent)))
           (setq buffer (find-file-noselect file))
           (with-current-buffer buffer ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (delete-file file))))

(ert-deftest my-modified-manual-restore-clears-flag-without-saving ()
  (my-modified-test-file "original\n"
    (goto-char 1) (insert "x") (delete-char -1)
    (should (buffer-modified-p))
    (let ((point-before (point)) (undo-before buffer-undo-list))
      (narrow-to-region 1 3)
      (my-modified-check-buffer)
      (should-not (buffer-modified-p))
      (should (= (point) point-before))
      (should (= (point-max) 3))
      (should (equal buffer-undo-list undo-before)))))

(ert-deftest my-modified-keeps-real-unsaved-edits ()
  (my-modified-test-file "original\n"
    (insert "new")
    (my-modified-check-buffer)
    (should (buffer-modified-p))))

(ert-deftest my-modified-restores-unicode-without-changing-the-file ()
  (my-modified-test-file (encode-coding-string "Привет 🌍\n" 'utf-8-unix)
    (let ((attributes (file-attributes file)))
      (insert "x") (delete-char -1)
      (my-modified-check-buffer)
      (should-not (buffer-modified-p))
      (should (equal (file-attribute-modification-time attributes)
                     (file-attribute-modification-time (file-attributes file)))))))

(ert-deftest my-modified-preserves-line-ending-changes ()
  (my-modified-test-file "original\r\n"
    (goto-char 1) (insert "x") (delete-char -1)
    (my-modified-check-buffer)
    (should-not (buffer-modified-p))
    (set-buffer-file-coding-system 'utf-8-unix)
    (my-modified-check-buffer)
    (should (buffer-modified-p))))

(ert-deftest my-modified-does-not-clear-unencodable-text ()
  (my-modified-test-file "?\n"
    (setq buffer-file-coding-system 'us-ascii-unix)
    (delete-char 1) (insert "Ж")
    (my-modified-check-buffer)
    (should (buffer-modified-p))))

(ert-deftest my-modified-keeps-new-deleted-and-externally-changed-files-dirty ()
  (my-modified-test-file "original\n"
    (insert "x") (delete-char -1)
    (set-file-times file (time-add (current-time) 10))
    (my-modified-check-buffer)
    (should (buffer-modified-p))
    (delete-file file)
    (my-modified-check-buffer)
    (should (buffer-modified-p))
    (with-temp-file file (insert "original\n"))))

(ert-deftest my-modified-idle-check-processes-queued-buffers ()
  (my-modified-test-file "original\n"
    (let ((my-modified-pending nil))
      (insert "x") (delete-char -1)
      (should (memq (current-buffer) my-modified-pending))
      (my-modified-check-pending)
      (should-not my-modified-pending)
      (should-not (buffer-modified-p)))))

(ert-deftest my-modified-skips-custom-serialization ()
  (my-modified-test-file "original\n"
    (insert "x") (delete-char -1)
    (setq-local buffer-file-format '(enriched))
    (my-modified-check-buffer)
    (should (buffer-modified-p))))
