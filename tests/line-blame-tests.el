;;; line-blame-tests.el --- Inline blame checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'package)
(setq user-emacs-directory (make-temp-file "emacs-line-blame-tests-" t)
      package-user-dir "/Volumes/Sources/emacs/elpa")
(package-initialize)
(load "/Volumes/Sources/emacs/arcadia.el" nil t)

(defconst lb-arc-json
  "{\"annotation\":[
 {\"date\":\"2026-11-14T10:00:00+03:00\",\"commit\":\"b\",\"text\":\"run()\\n\",\"author\":\"Анна Смирнова\",\"line\":2},
 {\"date\":\"2026-11-12T23:30:00+03:00\",\"commit\":\"a\",\"text\":\"x\\n\",\"author\":\"ivan\",\"line\":1}],
 \"commits\":[]}")

(ert-deftest line-blame-parses-arc-json ()
  (should (equal (line-blame--parse-arc lb-arc-json)
                 '(("12.11.2026" . "ivan") ("14.11.2026" . "Анна Смирнова")))))

(ert-deftest line-blame-parses-git-porcelain ()
  (let ((out (concat "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f 1 1 2\n"
                     "author Анна Смирнова\nauthor-mail <анна@пример.рф>\n"
                     ;; 2026-11-12 22:30 UTC, already the 13th in Moscow.
                     "author-time 1794522600\nauthor-tz +0300\n"
                     "summary x\nboundary\nfilename f\n\tauthor fake line\n"
                     "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f 2 2\n"
                     "author Ivan Petrov\nauthor-mail <>\nauthor-time 1794522600\nauthor-tz -0130\n"
                     "summary x\nfilename f\n\t\n"
                     "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f 3 3\n"
                     "author xpahos\nauthor-mail <xpahos@example.com>\nauthor-time 1794522600\n"
                     "author-tz +0000\nsummary x\nfilename f\n\tx\n")))
    ;; Email local part when present; the author name when the email is empty.
    (should (equal (line-blame--parse-git out)
                   '(("13.11.2026" . "анна") ("12.11.2026" . "Ivan Petrov")
                     ("12.11.2026" . "xpahos"))))))

(defun lb-wait (&optional seconds)
  "Wait until the current buffer's request settles."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and line-blame--request (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not line-blame--request)))

(defun lb-last-message ()
  (with-current-buffer (messages-buffer)
    (goto-char (point-max))
    (buffer-substring (line-beginning-position 0) (line-end-position 0))))

(defun lb-git (dir &rest args)
  (let ((default-directory dir))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %S: %s" args (buffer-string))))))

(defun lb-git-repo (files)
  "Create a Git repository committing FILES, an alist of (NAME . CONTENT)."
  (let ((dir (file-name-as-directory (make-temp-file "line-blame-git-" t))))
    (lb-git dir "init" "-q")
    (pcase-dolist (`(,name . ,content) files)
      (with-temp-file (expand-file-name name dir) (insert content)))
    (lb-git dir "add" ".")
    (lb-git dir "-c" "commit.gpgsign=false" "-c" "user.name=Анна Смирнова" "-c" "user.email=очень.длинный.никнейм@example.com"
            "commit" "-qm" "init")
    dir))

(defmacro lb-with-file (file &rest body)
  (declare (indent 1))
  `(let ((buffer (find-file-noselect ,file)) (inhibit-message t))
     (unwind-protect (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer)))))

(defun lb-prefixes ()
  (mapcar (lambda (o) (substring-no-properties (overlay-get o 'line-prefix)))
          (sort (overlays-in (point-min) (point-max))
                (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(ert-deftest line-blame-git-toggle-preserves-buffer ()
  (let ((dir (lb-git-repo '(("a.go" . "func main() {\n    run()\n}\n")))))
    (lb-with-file (expand-file-name "a.go" dir)
      (buffer-enable-undo)
      (goto-char 15)
      (let ((text (buffer-string)) (undo buffer-undo-list)
            (date (format-time-string "%d.%m.%Y")))
        (line-blame-mode 1)
        (lb-wait)
        (should line-blame-mode)
        (should (equal (lb-prefixes)
                       (make-list 3 (concat "│ " date "  очень.длинный.н… │ "))))
        (should (equal (string-width (overlay-get (car line-blame--overlays) 'wrap-prefix))
                       (string-width (car (lb-prefixes)))))
        (should (equal (buffer-string) text))
        (should (eq buffer-undo-list undo))
        (should-not (buffer-modified-p))
        (should (= (point) 15))
        (line-blame-mode -1)
        (should-not (overlays-in (point-min) (point-max)))
        (should (equal (buffer-string) text))
        (should (eq buffer-undo-list undo))
        (should-not (buffer-modified-p))))))

(ert-deftest line-blame-handles-empty-file-and-missing-final-newline ()
  (let ((dir (lb-git-repo '(("empty" . "") ("tail" . "one\ntwo")))))
    (lb-with-file (expand-file-name "empty" dir)
      (line-blame-mode 1)
      (lb-wait)
      (should line-blame-mode)
      (should-not (overlays-in (point-min) (point-max))))
    (lb-with-file (expand-file-name "tail" dir)
      (line-blame-mode 1)
      (lb-wait)
      (should (= (length (lb-prefixes)) 2))
      (should (= (overlay-end (car line-blame--overlays)) (point-max))))))

(ert-deftest line-blame-refuses-files-that-differ-from-head ()
  (let ((dir (lb-git-repo '(("a" . "a\n") ("b" . "b\n")))))
    (with-temp-file (expand-file-name "a" dir) (insert "changed\n"))
    (with-temp-file (expand-file-name "b" dir) (insert "staged\n"))
    (lb-git dir "add" "b")
    (with-temp-file (expand-file-name "new" dir) (insert "new\n"))
    (dolist (case '(("a" . "uncommitted") ("b" . "uncommitted") ("new" . "not tracked")))
      (lb-with-file (expand-file-name (car case) dir)
        (line-blame-mode 1)
        (lb-wait)
        (should-not line-blame-mode)
        (should-not (overlays-in (point-min) (point-max)))
        (should (string-match-p (cdr case) (lb-last-message)))))
    (lb-with-file (expand-file-name "a" dir)
      (insert "x")
      (should-error (line-blame-mode 1) :type 'user-error)
      (should-not line-blame-mode))))

(ert-deftest line-blame-hides-when-editing-begins ()
  (let ((dir (lb-git-repo '(("a" . "a\nb\n")))))
    (lb-with-file (expand-file-name "a" dir)
      (line-blame-mode 1)
      (lb-wait)
      (should line-blame--overlays)
      (insert "x")
      (should-not line-blame-mode)
      (should-not (overlays-in (point-min) (point-max)))
      (should (string-match-p "hidden" (lb-last-message))))))

;;; Arc, through a scripted executable

(defconst lb-fake-arc "#!/bin/sh
case \"$1\" in
  rev-parse)
    n=$(($(cat \"$LB_STATE/count\" 2>/dev/null || echo 0) + 1)); echo $n > \"$LB_STATE/count\"
    if [ -n \"$LB_HEAD_CHANGES\" ] && [ $n -gt 1 ]; then echo def; else echo abc; fi ;;
  status) cat \"$LB_STATE/status\" ;;
  blame)
    [ -n \"$LB_SLEEP\" ] && sleep \"$LB_SLEEP\"
    [ -n \"$LB_FAIL\" ] && { echo \"$LB_FAIL\" >&2; exit 1; }
    [ \"$2 $3 $4\" = \"--json abc a.go\" ] || exit 3
    cat \"$LB_STATE/blame\" ;;
esac
")

(defmacro lb-with-arc (env status &rest body)
  "Run BODY visiting a two-line a.go in a fake Arc mount."
  (declare (indent 2))
  `(let* ((root (file-name-as-directory (make-temp-file "line-blame-arc-" t)))
          (state (make-temp-file "line-blame-state-" t))
          (arc (expand-file-name "arc" state))
          (process-environment (append (cons (concat "LB_STATE=" state) ,env)
                                       process-environment)))
     (make-directory (expand-file-name ".arc" root))
     (write-region "" nil (expand-file-name ".arc/HEAD" root))
     (write-region "x\nrun()\n" nil (expand-file-name "a.go" root))
     (write-region lb-arc-json nil (expand-file-name "blame" state))
     (write-region ,status nil (expand-file-name "status" state))
     (write-region lb-fake-arc nil arc)
     (set-file-modes arc #o755)
     (let ((arcit-arc-executable arc))
       (cl-letf (((symbol-function 'vc-refresh-state) #'ignore))
         (lb-with-file (expand-file-name "a.go" root)
           (write-region "0" nil (expand-file-name "count" state))
           ,@body)))))

(ert-deftest line-blame-arc-renders-json ()
  (lb-with-arc nil "{\"status\":{}}"
    (line-blame-mode 1)
    (lb-wait)
    (should (equal (lb-prefixes) '("│ 12.11.2026  ivan          │ "
                                   "│ 14.11.2026  Анна Смирнова │ ")))))

(ert-deftest line-blame-arc-reports-untracked-and-failures ()
  (lb-with-arc nil "{\"status\":{\"untracked\":[{\"path\":\"a.go\"}]}}"
    (line-blame-mode 1)
    (lb-wait)
    (should-not line-blame-mode)
    (should (string-match-p "not tracked" (lb-last-message))))
  (lb-with-arc '("LB_FAIL=fatal: mount is offline") "{\"status\":{}}"
    (line-blame-mode 1)
    (lb-wait)
    (should-not line-blame-mode)
    (should-not (overlays-in (point-min) (point-max)))
    (should (string-match-p "arc blame failed: fatal: mount is offline" (lb-last-message)))))

(ert-deftest line-blame-ignores-results-for-a-changed-head ()
  (lb-with-arc '("LB_HEAD_CHANGES=1") "{\"status\":{}}"
    (line-blame-mode 1)
    (lb-wait)
    (should-not line-blame-mode)
    (should-not (overlays-in (point-min) (point-max)))
    (should (string-match-p "HEAD changed" (lb-last-message)))))

(ert-deftest line-blame-cancels-pending-work ()
  (lb-with-arc '("LB_SLEEP=1") "{\"status\":{}}"
    (line-blame-mode 1)
    (while (not (equal (process-command (car line-blame--request))
                       (list arcit-arc-executable "blame" "--json" "abc" "a.go")))
      (accept-process-output nil 0.05))
    (let ((process (car line-blame--request)))
      (line-blame-mode -1)
      (should-not (process-live-p process)))
    ;; A newer request wins over the older one it replaced.
    (line-blame-mode 1)
    (let ((old line-blame--request))
      (line-blame-mode -1)
      (line-blame-mode 1)
      (should-not (eq old line-blame--request)))
    (lb-wait 5)
    (should (= (length line-blame--overlays) 2))
    (should (= (length (overlays-in (point-min) (point-max))) 2))
    ;; Killing the buffer stops the request.
    (line-blame-mode -1)
    (line-blame-mode 1)
    (let ((process (car line-blame--request)))
      (set-buffer-modified-p nil)
      (kill-buffer)
      (should-not (process-live-p process)))))

(defun lb-wait-for-blame-process ()
  (while (not (equal (process-command (car line-blame--request))
                     (list arcit-arc-executable "blame" "--json" "abc" "a.go")))
    (accept-process-output nil 0.05))
  (car line-blame--request))

(ert-deftest line-blame-reenabling-while-loading-replaces-the-request ()
  (lb-with-arc '("LB_SLEEP=1") "{\"status\":{}}"
    (line-blame-mode 1)
    (let ((old (lb-wait-for-blame-process)))
      (line-blame-mode 1)
      (should-not (process-live-p old))
      (should line-blame-mode)
      (should line-blame--request))
    (lb-wait 5)
    (should line-blame-mode)
    (should (= (length (overlays-in (point-min) (point-max))) 2))))

(ert-deftest line-blame-major-mode-change-removes-annotations ()
  (lb-with-arc nil "{\"status\":{}}"
    (line-blame-mode 1)
    (lb-wait)
    (should (overlays-in (point-min) (point-max)))
    (text-mode)
    (should-not (overlays-in (point-min) (point-max)))
    (should-not (memq #'line-blame--cleanup change-major-mode-hook))))

(ert-deftest line-blame-major-mode-change-cancels-loading ()
  (lb-with-arc '("LB_SLEEP=1") "{\"status\":{}}"
    (line-blame-mode 1)
    (let ((process (lb-wait-for-blame-process)))
      (text-mode)
      (should-not (process-live-p process)))
    (sleep-for 1.5)
    (should-not (overlays-in (point-min) (point-max)))
    (should-not (seq-some (lambda (p) (equal (process-name p) "line-blame"))
                          (process-list)))))
