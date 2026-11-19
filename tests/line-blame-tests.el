;;; line-blame-tests.el --- Inline blame checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'package)
(defconst my-test-config-dir
  (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(setq user-emacs-directory (make-temp-file "emacs-line-blame-tests-" t)
      package-user-dir (expand-file-name "elpa" my-test-config-dir))
(package-initialize)
(load (expand-file-name "arcadia.el" my-test-config-dir) nil t)

(defconst lb-arc-json
  "{\"annotation\":[
 {\"date\":\"2026-11-14T10:00:00+03:00\",\"commit\":\"b\",\"text\":\"run()\\n\",\"author\":\"Анна Смирнова\",\"line\":2},
 {\"date\":\"2026-11-12T23:30:00+03:00\",\"commit\":\"a\",\"text\":\"x\\n\",\"author\":\"ivan\",\"line\":1}],
 \"commits\":[]}")

(ert-deftest line-blame-parses-arc-json ()
  (should (equal (line-blame--parse-arc lb-arc-json)
                 '(("12.11.2026" "ivan" "a" "12.11.2026, 23:30" "")
                   ("14.11.2026" "Анна Смирнова" "b" "14.11.2026, 10:00" "")))))

(ert-deftest line-blame-parses-arc-commit-metadata ()
  (let* ((json (json-serialize
                `(:annotation
                  [(:date "2026-07-31T18:48:02+03:00" :commit "c1" :author "andreyshunin" :line 1)
                   (:date "2026-07-30T09:05:00+03:00" :commit "c2" :author "anna" :line 2)
                   (:date "2026-07-29T09:05:00+03:00" :commit "c3" :author "ivan" :line 3)]
                  :commits
                  [(:commit "c1" :author "andreyshunin"
                    :message "CLOUD-1: gpud\nduring init\n\nREVIEW: 14616115"
                    :attributes (:pr.id "14616115"))
                   (:commit "c2" :author "anna" :message "Fix\n"
                    :attributes (:pr.id "777"))
                   (:commit "c3" :author "ivan" :message "No review")])))
         (entries (line-blame--parse-arc json)))
    (should (equal (mapcar (lambda (e) (nth 4 e)) entries)
                   ;; Review from metadata is added once, never duplicated.
                   '("CLOUD-1: gpud\nduring init\n\nREVIEW: 14616115"
                     "Fix\n\nREVIEW: 777" "No review")))
    (should (equal (nth 3 (car entries)) "31.07.2026, 18:48"))
    (should (equal (line-blame--details (car entries) (nth 4 (car entries)))
                   (concat "commit c1\nAuthor: andreyshunin\nDate: 31.07.2026, 18:48\n\n"
                           "CLOUD-1: gpud\nduring init\n\nREVIEW: 14616115")))))

(ert-deftest line-blame-parses-git-porcelain ()
  (let ((out (concat "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f 1 1 2\n"
                     "author Анна Смирнова\nauthor-mail <анна@пример.рф>\n"
                     ;; 2026-11-12 22:30 UTC, already the 13th in Moscow.
                     "author-time 1794522600\nauthor-tz +0300\n"
                     "summary x\nboundary\nfilename f\n\tauthor fake line\n"
                     "8d8f55d82b2725f9be9e44b55cfdc0a8cb0b4975 2 2\n"
                     "author Ivan Petrov\nauthor-mail <>\nauthor-time 1794522600\nauthor-tz -0130\n"
                     "summary x\nfilename f\n\t\n"
                     "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f 3 3\n"
                     "author xpahos\nauthor-mail <xpahos@example.com>\nauthor-time 1794522600\n"
                     "author-tz +0000\nsummary x\nfilename f\n\tx\n")))
    ;; Email local part when present; the author name when the email is empty.
    (should (equal (line-blame--parse-git out)
                   '(("13.11.2026" "анна" "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f"
                      "13.11.2026, 01:30" nil)
                     ("12.11.2026" "Ivan Petrov" "8d8f55d82b2725f9be9e44b55cfdc0a8cb0b4975"
                      "12.11.2026, 21:00" nil)
                     ("12.11.2026" "xpahos" "e5a58b0d17d40d9212613fdb1c2387ccf0f3e21f"
                      "12.11.2026, 22:30" nil))))))

(ert-deftest line-blame-shades-by-date ()
  (should (= (line-blame--day "02.01.1970") 1))
  ;; Five equal slices of the range; newest is darkest (4).
  (should (equal (mapcar (lambda (d) (line-blame--shade d 10 14)) '(10 11 12 13 14))
                 '(0 1 2 3 4)))
  (should (equal (mapcar (lambda (d) (line-blame--shade d 0 99)) '(0 19 20 99)) '(0 0 1 4)))
  ;; One distinct date: a single shade.
  (should (= (line-blame--shade 7 7 7) 0))
  (let ((faces (line-blame--shade-faces)))
    (should (= (length faces) 5))
    (should (= (length (delete-dups (copy-sequence faces))) (if (car faces) 5 1)))))

(ert-deftest line-blame-fills-only-long-message-lines ()
  (let ((long (mapconcat #'identity (make-list 30 "word") " ")))
    (should (equal (line-blame--fill "short\n\nREVIEW: 1") "short\n\nREVIEW: 1"))
    (should (cl-every (lambda (line) (<= (length line) 72))
                      (split-string (line-blame--fill long) "\n")))
    (should (> (length (split-string (line-blame--fill long) "\n")) 1))))

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

;;; Shading and hover

(defvar lb-mouse nil "Target the stubbed pointer is over.")
(defvar lb-tips nil "Texts passed to the stubbed `posframe-show', newest first.")
(defvar lb-hides 0)

(ert-deftest line-blame-hover-ignores-pointer-outside-frame ()
  (dolist (xy '((-1 . 20) (20 . -1) (nil . 20)))
    (cl-letf (((symbol-function 'mouse-pixel-position)
               (lambda () (cons (selected-frame) xy)))
              ((symbol-function 'posn-at-x-y)
               (lambda (&rest _) (ert-fail "Invalid coordinates reached posn-at-x-y"))))
      (should-not (line-blame--target-at-mouse)))))

(defun lb-two-commit-repo ()
  "Repository whose a.txt has lines from two commits on different days."
  (let ((dir (file-name-as-directory (make-temp-file "line-blame-hover-" t))))
    (lb-git dir "init" "-q")
    (write-region "one\n" nil (expand-file-name "a.txt" dir))
    (lb-git dir "add" ".")
    (let ((process-environment (cons "GIT_AUTHOR_DATE=2026-07-01T10:00:00+0300"
                                     process-environment)))
      (lb-git dir "-c" "commit.gpgsign=false" "-c" "user.name=Ivan" "-c" "user.email=ivan@x"
              "commit" "-qm" "First: old\n\nREVIEW: 11"))
    (write-region "one\ntwo\n" nil (expand-file-name "a.txt" dir))
    (let ((process-environment (cons "GIT_AUTHOR_DATE=2026-07-31T18:48:00+0300"
                                     process-environment)))
      (lb-git dir "-c" "commit.gpgsign=false" "-c" "user.name=Andrey" "-c" "user.email=andreyshunin@x"
              "commit" "-qam" "CLOUD-2: second"))
    dir))

(defmacro lb-with-hover (&rest body)
  "Run BODY with blame shown for a two-commit file and a stubbed pointer."
  (declare (indent 0))
  `(let ((dir (lb-two-commit-repo)) (lb-mouse nil) (lb-tips nil) (lb-hides 0))
     (clrhash line-blame--messages)
     (cl-letf (((symbol-function 'line-blame--target-at-mouse) (lambda () lb-mouse))
               ((symbol-function 'posframe-show)
                (lambda (_buffer &rest args)
                  (push (substring-no-properties (plist-get args :string)) lb-tips)))
               ((symbol-function 'frame-edges) (lambda (&rest _) '(0 0 1000 800)))
               ((symbol-function 'posframe-hide) (lambda (_) (cl-incf lb-hides))))
       (lb-with-file (expand-file-name "a.txt" dir)
         (set-window-buffer (selected-window) (current-buffer))
         (line-blame-mode 1)
         (lb-wait)
         ,@body))))

(defun lb-target (line)
  "A fresh pointer target over LINE's annotation."
  (let ((overlay (cl-find-if (lambda (o) (= (line-number-at-pos (overlay-start o)) line))
                             line-blame--overlays)))
    (cl-list* (selected-window) (overlay-get overlay 'line-prefix) 10 20)))

(defun lb-sleep (seconds)
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end) (accept-process-output nil 0.02))))

(ert-deftest line-blame-shades-only-date-and-nickname ()
  (lb-with-hover
    (let* ((old (overlay-get (car (last line-blame--overlays)) 'line-prefix))
           (new (overlay-get (car line-blame--overlays) 'line-prefix))
           (middle (lambda (s) (get-text-property 2 'face s))))
      (should (string-match-p "\\`│ 01\\.07\\.2026  ivan         │ \\'" old))
      (should (string-match-p "\\`│ 31\\.07\\.2026  andreyshunin │ \\'" new))
      ;; Separators keep the plain annotation face; only the middle is shaded.
      (dolist (s (list old new))
        (should (eq (get-text-property 0 'face s) 'line-blame))
        (should (eq (get-text-property (- (length s) 2) 'face s) 'line-blame))
        (should (eq (cadr (funcall middle s)) 'line-blame))
        (should (get-text-property 2 'line-blame-entry s))
        (should-not (get-text-property 0 'line-blame-entry s))
        (should-not (get-text-property (1- (length s)) 'line-blame-entry s)))
      (should (equal (car (funcall middle old)) (nth 0 (line-blame--shade-faces))))
      (should (equal (car (funcall middle new)) (nth 4 (line-blame--shade-faces))))
      ;; Continuation prefixes are blank and never hoverable.
      (let ((wrap (overlay-get (car line-blame--overlays) 'wrap-prefix)))
        (should (string-blank-p wrap))
        (should-not (text-property-any 0 (length wrap) 'line-blame-entry
                                       (get-text-property 2 'line-blame-entry new) wrap))))))

(ert-deftest line-blame-hover-waits-and-keeps-delay-within-annotation ()
  (lb-with-hover
    (setq lb-mouse (lb-target 2))
    (lb-sleep 0.25)
    ;; A fresh target object for the same line does not restart the delay.
    (setq lb-mouse (lb-target 2))
    (lb-sleep 0.1)
    (should-not lb-tips)
    (lb-sleep 0.3)
    (should (= (length lb-tips) 1))
    (should (string-match-p "\\`commit [0-9a-f]\\{40\\}\nAuthor: andreyshunin\nDate: 31\\.07\\.2026, 18:48\n\nCLOUD-2: second\\'"
                            (car lb-tips)))
    (should line-blame--shown)
    ;; Leaving hides at once, at the next poll.
    (setq lb-mouse nil)
    (lb-sleep 0.1)
    (should-not line-blame--shown)
    (should (= lb-hides 1))))

(ert-deftest line-blame-brief-pass-shows-nothing ()
  (lb-with-hover
    (setq lb-mouse (lb-target 1))
    (lb-sleep 0.15)
    (setq lb-mouse nil)
    (lb-sleep 0.6)
    (should-not lb-tips)
    (should-not (gethash (cons line-blame--root (nth 2 (car (line-blame--parse-git ""))))
                         line-blame--fetching))))

(ert-deftest line-blame-hover-switching-lines-and-stale-results ()
  (lb-with-hover
    (setq lb-mouse (lb-target 1))
    ;; Wait until line 1's message is being fetched, then move to line 2.
    (let ((deadline (+ (float-time) 5)))
      (while (and (zerop (hash-table-count line-blame--fetching)) (< (float-time) deadline))
        (accept-process-output nil 0.005)))
    (should (= (hash-table-count line-blame--fetching) 1))
    (setq lb-mouse (lb-target 2))
    (line-blame--poll)
    (lb-sleep 0.2)
    ;; Line 1's late result is cached but never shown for line 2.
    (should-not lb-tips)
    (should (= (hash-table-count line-blame--messages) 1))
    (lb-sleep 0.5)
    (should (= (length lb-tips) 1))
    (should (string-match-p "CLOUD-2" (car lb-tips)))
    ;; Back to line 1: old tip hides at once, a new delay starts, cache is reused.
    (setq lb-mouse (lb-target 1))
    (line-blame--poll)
    (should-not line-blame--shown)
    (should (>= lb-hides 1))
    (lb-sleep 0.5)
    (should (string-match-p "First: old\n\nREVIEW: 11" (car lb-tips)))
    (should (zerop (hash-table-count line-blame--fetching)))))

(ert-deftest line-blame-hover-cache-is-per-repository ()
  (lb-with-hover
    (let ((commit (nth 2 (get-text-property 2 'line-blame-entry (cadr (lb-target 2))))))
      (puthash (cons "/other/repo/" commit) "WRONG" line-blame--messages)
      (setq lb-mouse (lb-target 2))
      (lb-sleep 0.7)
      (should (string-match-p "CLOUD-2" (car lb-tips)))
      (should (equal (gethash (cons line-blame--root commit) line-blame--messages)
                     "CLOUD-2: second")))))

(ert-deftest line-blame-hover-failure-is-reported-once ()
  (lb-with-hover
    (let ((vc-git-program "/usr/bin/false") (starts 0))
      (advice-add 'make-process :before (lambda (&rest _) (cl-incf starts)) '((name . lb-count)))
      (unwind-protect
          (progn
            (setq lb-mouse (lb-target 2))
            (lb-sleep 0.7)
            (should (string-match-p "Commit message unavailable" (car lb-tips)))
            ;; Moving within the line, or re-hovering it, starts nothing new.
            (setq lb-mouse (lb-target 2))
            (lb-sleep 0.1)
            (setq lb-mouse nil)
            (lb-sleep 0.1)
            (setq lb-mouse (lb-target 2))
            (lb-sleep 0.6)
            (should (= starts 1))
            (should (= (length lb-tips) 2)))
        (advice-remove 'make-process 'lb-count)))))

(ert-deftest line-blame-hover-cleanup-hides-and-stops-timers ()
  (dolist (action (list (lambda () (line-blame-mode -1))
                        (lambda () (insert "x"))
                        (lambda () (text-mode))
                        (lambda () (set-buffer-modified-p nil) (kill-buffer))))
    (lb-with-hover
      (setq lb-mouse (lb-target 2))
      (lb-sleep 0.6)
      (should line-blame--shown)
      (setq lb-mouse (lb-target 1))
      (line-blame--poll)
      (should line-blame--delay-timer)
      (funcall action)
      (should-not line-blame--shown)
      (should-not line-blame--delay-timer)
      (should-not line-blame--poll-timer)
      (should-not line-blame--buffers)
      (lb-sleep 0.5)
      (should (= (length lb-tips) 1)))))
