;;; pi-history-fixtures.el --- Synthetic conversations -*- lexical-binding: t; -*-
(require 'json)
(defun pi-test-jsonl (file entries &optional tail)
  (with-temp-file file
    (dolist (entry entries) (insert (decode-coding-string (json-serialize entry) 'utf-8) "\n"))
    (when tail (insert tail))))

(defun pi-test-message (id parent role text &optional stamp)
  `((type . "message") (id . ,id) (parentId . ,(or parent :null))
    (timestamp . ,(or stamp "2026-11-16T10:00:00Z"))
    (message . ((role . ,role) (stopReason . "stop")
                (content . [((type . "text") (text . ,text))])))))

