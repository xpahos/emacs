;;; project-search-tests.el --- Safe project file selection -*- lexical-binding: t; -*-
(load (expand-file-name "projects-tests.el" (file-name-directory load-file-name)) nil t)
(load (expand-file-name "../project-search.el" (file-name-directory load-file-name)) t t)

(ert-deftest my-project-search-keeps-all-path-fragments ()
  (let* ((files '("cloud/compute/go/common/pkg/hw/pci/class.go"
                  "cloud/compute/go/other/class.go"))
         (table (project--file-completion-table files)))
    (dolist (query '("cloud/compute/go/common/pkg/hw/pci/class.go"
                     "go/common/pkg/hw/pci/class.go"
                     "common/pkg/hw/pci/class.go"))
      (should (completion-all-completions query table nil (length query))))))

(ert-deftest my-project-search-does-not-detect-or-query-vcs ()
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (&rest _) (error "File search must not detect a VCS"))))
    (let* ((root "/tmp/plain folder/cloud/compute/go/")
           (spec (my-project-search-source root)))
      (should (equal (car spec) root))
      (should (equal (cadr spec) find-program))
      (should (member root (cdr spec))))))

(ert-deftest my-project-search-works-without-an-open-project ()
  (my-test-projects
   (let* ((default-directory test-root)
          (file (expand-file-name "standalone.txt" test-root)))
     (with-temp-file file (insert "example\n"))
     (cl-letf (((symbol-function 'my-project-read-file)
                (lambda (root) (should (equal root test-root)) file)))
       (my-project-find-file)
       (should (equal buffer-file-name file))))))

(ert-deftest my-project-search-rejects-empty-and-nonfile-results ()
  (my-test-projects
   (my-project-open test-root)
   (let ((original (current-buffer)))
     (dolist (answer '(nil "" "subdirectory/" "not-a-result.go"))
       (cl-letf (((symbol-function 'my-project-read-file) (lambda (_) answer)))
         (should-error (my-project-find-file) :type 'user-error)
         (should (eq (current-buffer) original)))))))

(ert-deftest my-project-search-cancel-preserves-current-file ()
  (my-test-projects
   (my-project-open test-root)
   (let ((original (current-buffer)) (windows (window-list)))
     (cl-letf (((symbol-function 'my-project-read-file) (lambda (_) (signal 'quit nil))))
       (condition-case nil (my-project-find-file) (quit nil)))
     (should (eq (current-buffer) original))
     (should (equal (window-list) windows)))))

(ert-deftest my-project-search-lists-local-files-with-spaces ()
  (let* ((root (file-name-as-directory (make-temp-file "file-search-" t)))
         (file (expand-file-name "a file.txt" root)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "example\n"))
          (make-directory (expand-file-name "directory.txt" root))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (let ((deadline (+ (float-time) 3)))
                         (while (and (process-live-p (get-process "project-files"))
                                     (< (float-time) deadline))
                           (accept-process-output nil 0.05)))
                       (should (= (length (all-completions "" table)) 1))
                       (car (completion-all-completions "a file" table nil 6)))))
            (should (equal (my-project-read-file root) file))))
      (delete-directory root t))))

(ert-deftest my-project-search-refreshes-files-on-each-open ()
  (let* ((root (file-name-as-directory (make-temp-file "file-search-refresh-" t)))
         (old (expand-file-name "old.txt" root))
         (new (expand-file-name "new.txt" root))
         (expected old))
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (let ((deadline (+ (float-time) 3)))
                       (while (and (process-live-p (get-process "project-files"))
                                   (< (float-time) deadline))
                         (accept-process-output nil 0.05)))
                     (should (equal (all-completions "" table) (list expected)))
                     expected)))
          (with-temp-file old (insert "old\n"))
          (should (equal (my-project-read-file root) old))
          (delete-file old)
          (with-temp-file new (insert "new\n"))
          (setq expected new)
          (should (equal (my-project-read-file root) new)))
      (delete-directory root t))))

(ert-deftest my-project-search-prunes-git-metadata-only ()
  (let ((root (file-name-as-directory (make-temp-file "file-search-prune-" t))))
    (unwind-protect
        (progn
          (dolist (name '(".git/objects/object" "nested/.git/config"
                          ".github/workflows/test.yml" ".env" "untracked.txt"
                          "target/generated.txt" "worktree/.git"))
            (let ((file (expand-file-name name root)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file (insert "fixture\n"))))
          (let* ((source (my-project-search-source root))
                 (default-directory (car source)))
            (with-temp-buffer
              (should (zerop (apply #'call-process (cadr source) nil t nil (cddr source))))
              (should (equal (sort (mapcar (lambda (file) (file-relative-name file root))
                                          (split-string (buffer-string) "\0" t)) #'string<)
                             '(".env" ".github/workflows/test.yml" "target/generated.txt"
                               "untracked.txt" "worktree/.git"))))))
      (delete-directory root t))))
