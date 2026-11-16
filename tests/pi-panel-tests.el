;;; pi-panel-tests.el --- Pi panel regression checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'package)
(let* ((root (expand-file-name ".." (file-name-directory load-file-name)))
       (package-user-dir (expand-file-name "elpa" root))
       (user-emacs-directory (make-temp-file "pi-mode-line-" t)))
  (unwind-protect
      (progn
        (package-initialize)
        (load (expand-file-name "pi-panel.el" root) nil t))
    (delete-directory user-emacs-directory t)))

(ert-deftest my-pi-mode-line-keeps-one-interactive-thinking-control ()
  ;; Other agents and legacy pi versions must retain their session mode.
  (dolist (case '((pi t 1) (other t 2) (pi nil 1)))
    (pcase-let ((`(,agent ,thought-option ,count) case))
      (with-temp-buffer
        (setq major-mode 'agent-shell-mode)
        (setq-local agent-shell--state
                    `((:buffer . ,(current-buffer))
                      (:agent-config . ((:identifier . ,agent)))
                      (:session . ((:mode-id . "medium")
                                   (:modes . (((:id . "medium") (:name . "Thinking: medium"))))
                                   (:config-options .
                                    ,(when thought-option
                                       '(((:id . "thought_level")
                                          (:category . "thought_level")
                                          (:current-value . "medium")
                                          (:options . (((:value . "medium")
                                                        (:name . "Thinking: medium"))))))))))))
        (my-pi-setup-mode-line)
        (let* ((before (copy-tree agent-shell--state))
               (line (eval (cadr (cadr mode-line-format)) t))
               (start (string-match "Thinking" line))
               (map (and start (get-text-property start 'local-map line))))
          (should (= count (1- (length (split-string line "Thinking")))))
          (should (keymapp (lookup-key map [mode-line mouse-1])))
          (when thought-option
            (should (eq (get-text-property start 'face line) 'agent-shell-thought-level))
            (should (lookup-key (lookup-key map [mode-line mouse-1]) [thought-level-medium])))
          (should (equal before agent-shell--state)))))))

(ert-deftest my-pi-reloaded-buffer-tracks-running-turns ()
  (let* ((user-emacs-directory (make-temp-file "pi-reload-" t))
         (my-pi-history-db nil)
         (my-pi-sessions (make-hash-table :test #'equal))
         (process (make-pipe-process :name "pi-test" :noquery t)))
    (unwind-protect
        (with-temp-buffer
          ;; agent-shell-reload creates a fresh buffer without my-pi-start-chat.
          (setq major-mode 'agent-shell-mode default-directory user-emacs-directory)
          (setq-local shell-maker--config (make-shell-maker-config :name "Agent")
                      agent-shell--state
                      (agent-shell--make-state :buffer (current-buffer)
                                               :agent-config '((:identifier . pi))))
          (setf (map-elt agent-shell--state :client) `((:process . ,process))
                (map-elt (map-elt agent-shell--state :session) :id) "reloaded")
          (my-pi-attach)
          (should (equal my-pi-root (my-pi-history-root default-directory)))
          (my-pi-attach)
          (should (= 1 (length (map-elt agent-shell--state :event-subscriptions))))
          (agent-shell--emit-event :event 'input-submitted :data '((:prompt . "hello")))
          (should (equal (plist-get (my-pi-history-get "reloaded") :turn_state) "running"))
          (should (string-match-p "1 running" my-pi-header))
          (cl-letf (((symbol-function 'my-pi-history-refresh) #'ignore))
            (agent-shell--emit-event :event 'turn-complete :data '((:stop-reason . "end_turn"))))
          (should (string-match-p "0 running" my-pi-header))
          ;; Loading the fix into an already busy buffer repairs missed input events.
          (setq-local shell-maker--busy t)
          (my-pi-attach)
          (should (string-match-p "1 running" my-pi-header)))
      (delete-process process)
      (when my-pi-history-db (sqlite-close my-pi-history-db))
      (delete-directory user-emacs-directory t))))

