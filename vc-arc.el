;;; vc-arc.el --- Read-only VC support for Arc gutters -*- lexical-binding: t; -*-

(require 'vc)
(require 'vc-dispatcher)
(require 'arcit)

(define-error 'vc-arc-unavailable "Arc is temporarily unavailable")

(defun vc-arc-root (file)
  "Return FILE's local Arc root without crossing a nested Git repository."
  (unless (file-remote-p file)
    (when-let* ((root (vc-find-root
                      file (lambda (directory)
                             (or (file-exists-p (expand-file-name ".git" directory))
                                 (file-exists-p (expand-file-name ".arc/HEAD" directory)))))))
      ;; ~/.arc holds client settings, not a checkout.
      (unless (file-exists-p (expand-file-name ".git" root)) root))))

(defalias 'vc-arc-responsible-p #'vc-arc-root)

(defun vc-arc--output (file &rest args)
  "Run Arc ARGS at FILE's root, preserving the output verbatim."
  (let* ((default-directory (or (vc-arc-root file)
                                (error "Not in an Arc mount: %s" file)))
         (arcit--mount-path-alist `((nil . ,default-directory)))
         (process (arcit-async-arc args)))
    (unwind-protect
        (progn
          (arcit-await-arc process)
          ;; Arcit's stdout slot trims whitespace, which changes file contents.
          (with-current-buffer (oref process stdout-buffer)
            (buffer-substring-no-properties (point-min) (point-max))))
      (when (process-live-p (oref process process))
        (delete-process (oref process process))))))

(defun vc-arc-registered (file)
  "Return non-nil when FILE is tracked by Arc."
  (when-let* ((root (vc-arc-root file))
              (_ (executable-find arcit-arc-executable)))
    (condition-case err
        (let ((relative (file-relative-name file root)))
          (equal (string-trim-right
                  (vc-arc--output file "ls-files" "--cached" "--" relative) "\n")
                 relative))
      ;; Returning nil would make VC cache this file as unregistered.
      (error (signal 'vc-arc-unavailable (list (error-message-string err)))))))

(defun vc-arc-state (file)
  "Return the VC state of FILE, including staged changes."
  (condition-case err
      (let* ((result (json-parse-string
                      (vc-arc--output file "status" "--json" "--ignored" "--branch"
                                      "--no-ahead-behind" "--no-sync-status"
                                      "--no-bisect-status" "--" file)
                      :object-type 'alist :array-type 'list))
             (local (alist-get 'local (alist-get 'branch_info result)))
             (status (alist-get 'status result))
             (staged (alist-get 'status (car (alist-get 'staged status)))))
        (vc-file-setprop file 'vc-arc-state-error nil)
        (vc-file-setprop file 'vc-arc-branch (alist-get 'name local))
        (vc-file-setprop file 'vc-arc-head (alist-get 'id (alist-get 'commit local)))
        (cond ((alist-get 'unmerged status) 'conflict)
              ((alist-get 'ignored status) 'ignored)
              ((alist-get 'untracked status) 'unregistered)
              ((member staged '("new file" "copied" "renamed")) 'added)
              ((equal staged "deleted") 'removed)
              ((or (alist-get 'changed status) (alist-get 'staged status)) 'edited)
              (t 'up-to-date)))
    (error
     (vc-file-setprop file 'vc-arc-state-error (error-message-string err))
     (message "Arc status unavailable: %s" (error-message-string err))
     (vc-file-getprop file 'vc-state))))

(defun vc-arc-working-revision (file)
  "Return the current commit ID for FILE's mount."
  (string-trim (vc-arc--output file "rev-parse" "HEAD")))

(defun vc-arc-mode-line-string (file)
  "Show FILE's branch from the latest status response without another Arc call."
  (pcase-let* ((`(,state-echo ,face ,_) (vc-mode-line-state (vc-state file 'Arc)))
               (branch (vc-file-getprop file 'vc-arc-branch))
               (head (vc-file-getprop file 'vc-arc-head)))
    (propertize (cond ((and branch (not (string-empty-p branch))) branch)
                      (head (concat "detached@" (substring head 0 (min 7 (length head)))))
                      (t "unknown"))
                'face face 'help-echo
                (concat state-echo " under Arc\nCurrent revision: " head))))

(defun vc-arc-checkout-model (_files)
  'implicit)

(defun vc-arc-find-revision (file revision buffer)
  "Insert FILE at REVISION into BUFFER without changing whitespace."
  (let* ((coding-system-for-read 'no-conversion)
         (path (file-relative-name file (vc-arc-root file)))
         (text (vc-arc--output file "show" (concat (or revision "HEAD") ":" path))))
    (with-current-buffer buffer (insert text)))
  0)

(defun vc-arc-diff (files &optional rev1 rev2 buffer async)
  "Diff FILES against REV1, or between REV1 and REV2, optionally ASYNC."
  (let ((default-directory (vc-arc-root (car files))))
    (apply #'vc-do-command (or buffer "*vc-diff*")
           (if async 'async 0) arcit-arc-executable files
           "diff" "--git" "--no-color"
           (append (vc-switches nil 'diff)
                   (list (or rev1 "HEAD"))
                   (when rev2 (list rev2))
                   '("--")))))

(provide 'vc-arc)
