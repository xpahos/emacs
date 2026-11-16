;;; worktrees-arc-tests.el --- Opt-in checks against a real Arc client -*- lexical-binding: t; -*-
;; Runs only with EMACS_TEST_REAL_ARC=1.  EMACS_TEST_ARC_SOURCE names a
;; directory inside an existing mount (default ~/arc/cloudia/cloud).  The
;; source mount is only read; the test mounts and forgets one temporary copy.
(load (expand-file-name "worktrees-tests.el" (file-name-directory load-file-name)) nil t)

(ert-deftest my-wt-real-arc-create-and-forget ()
  (skip-unless (equal (getenv "EMACS_TEST_REAL_ARC") "1"))
  (my-wt-test
   (let* ((arcit-arc-executable (expand-file-name "~/bin/arc"))
          (source-dir (file-name-as-directory (or (getenv "EMACS_TEST_ARC_SOURCE") (expand-file-name "~/arc/cloudia/cloud"))))
          (source (my-wt-register source-dir))
          (info (my-wt-json (cdr (my-wt-call source-dir arcit-arc-executable "info" "--json"))))
          (before (cdr (my-wt-call (plist-get source :vcs_root) arcit-arc-executable "info" "--json")))
          copy)
     (should (equal (plist-get source :vcs) "arc"))
     (puthash (plist-get source :directory) (list :repository (plist-get info :repository)) my-wt-branches)
     (unwind-protect
         (progn
           ;; The remote head is published, so a fresh store can load it.
           (setq copy (my-wt-test-create source (list :branch (format "emacs-wt-optin-%s" (my-pi-history-id)) :new t
                                                     :start (plist-get info :remote_head) :sha (plist-get info :remote_head))))
           (should (equal (plist-get copy :state) "ready"))
           (should (file-directory-p (plist-get copy :directory)))
           (should-not (equal (plist-get copy :arc_store) (plist-get (my-wt-mount-entry (my-wt-json (cdr (my-wt-call user-emacs-directory arcit-arc-executable "mount" "--list" "--json"))) (plist-get source :vcs_root)) :store)))
           (let (done)
             (my-wt-delete copy (lambda (error) (setq done (or error 'ok))))
             (my-wt-test-wait (lambda () done) 120)
             (should (eq done 'ok)))
           (should-not (file-exists-p (plist-get copy :vcs_root)))
           (should (equal before (cdr (my-wt-call (plist-get source :vcs_root) arcit-arc-executable "info" "--json")))))
       ;; Test cleanup only: forget the temporary mount if the code under test refused to.
       (when (and copy (file-exists-p (plist-get copy :vcs_root)))
         (my-wt-call user-emacs-directory arcit-arc-executable "unmount" "--forget"
                     (directory-file-name (plist-get copy :vcs_root))))))))
