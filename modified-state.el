;;; modified-state.el --- Clear dirty flags after manually restoring text -*- lexical-binding: t; -*-

(require 'cl-lib)
(defvar my-modified-pending nil)
(defvar my-modified-timer nil)

(defun my-modified-check-buffer ()
  "Clear the dirty flag only when this buffer encodes to its unchanged file."
  (when (and buffer-file-name (buffer-modified-p)
             (not (file-remote-p buffer-file-name))
             (not (find-file-name-handler buffer-file-name 'insert-file-contents-literally))
             (not (or buffer-file-format write-contents-functions
                      write-file-functions write-region-annotate-functions))
             ;; shortcut: check small plain files; use background I/O for large files.
             (<= (buffer-size) (* 5 1024 1024)))
    (condition-case nil
        (when (and (file-regular-p buffer-file-name)
                   (<= (file-attribute-size (file-attributes buffer-file-name))
                       (* 5 1024 1024))
                   (verify-visited-file-modtime (current-buffer)))
          (save-restriction
            (widen)
            (let* ((file buffer-file-name)
                   (coding (or buffer-file-coding-system 'utf-8-unix))
                   (last-coding-system-used nil)
                   (text (buffer-substring-no-properties (point-min) (point-max)))
                   (bytes (encode-coding-string text coding)))
              (when (and (equal text (decode-coding-string bytes coding))
                         ;; Lengths nearly always differ; skip reading the file then.
                         (= (length bytes)
                            (file-attribute-size (file-attributes file)))
                         (equal bytes
                                (with-temp-buffer
                                  (set-buffer-multibyte nil)
                                  (insert-file-contents-literally file)
                                  (buffer-string)))
                         (verify-visited-file-modtime (current-buffer)))
                (set-buffer-modified-p nil)))))
      (error nil))))

(defun my-modified-queue (&rest _)
  "Queue an edited file buffer for one comparison after an idle pause."
  (when buffer-file-name
    (cl-pushnew (current-buffer) my-modified-pending)))

(defun my-modified-check-pending ()
  "Check each queued live buffer once, without changing the selected window."
  (let ((buffers my-modified-pending))
    (setq my-modified-pending nil)
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (my-modified-check-buffer))))))

(add-hook 'after-change-functions #'my-modified-queue)
(when (timerp my-modified-timer) (cancel-timer my-modified-timer))
(setq my-modified-timer nil)
(unless noninteractive
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (buffer-modified-p) (my-modified-queue))))
  (setq my-modified-timer
        (run-with-idle-timer 1 t #'my-modified-check-pending)))

(provide 'my-modified-state)
