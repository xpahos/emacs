;;; pi-panel.el --- Project Pi chats in a resizable side window -*- lexical-binding: t; -*-

(require 'agent-shell)
(require 'agent-shell-pi)
(load (expand-file-name "pi-history.el" (file-name-directory load-file-name)) nil t)

(defvar my-pi-buffers (make-hash-table :test #'equal))
(defvar-local my-pi-root nil)
(defvar-local my-pi-width 0.33)
(defvar-local my-pi-return-window nil)

(setq agent-shell-pi-acp-command
      (list (expand-file-name "tools/pi-acp/node_modules/.bin/pi-acp"
                              (file-name-directory load-file-name)))
      agent-shell-preferred-agent-config 'pi
      agent-shell-session-strategy 'new
      agent-shell-header-style nil)

(defun my-pi-setup-mode-line ()
  "Keep the agent's interactive controls in the bottom line."
  (setq-local header-line-format '(:eval (list my-pi-header))
              mode-line-format '("%e" (:eval (agent-shell--mode-line-format)))))

(add-hook 'agent-shell-mode-hook #'my-pi-setup-mode-line)
(defun my-pi-data-directory (subdir)
  "Store agent SUBDIR outside the project tree."
  (expand-file-name (concat "pi/" (secure-hash 'sha256 (agent-shell-cwd)) "/" subdir)
                    user-emacs-directory))

(setq agent-shell-dot-subdir-function #'my-pi-data-directory)

(defun my-pi-display-buffer (buffer _alist)
  "Show Pi BUFFER on the right, preserving its last chosen width."
  (with-current-buffer buffer
    (setq-local my-pi-root (file-name-as-directory (file-truename default-directory))
                tab-line-format nil
                window-size-fixed nil)
    (puthash my-pi-root buffer my-pi-buffers)
    (display-buffer-in-side-window
     buffer `((side . right) (slot . 0) (window-width . ,my-pi-width)
              (window-parameters . ((my-pi-panel . t)
                                    (no-other-window . t)
                                    (no-delete-other-windows . t)))))))

(setq agent-shell-display-action '(my-pi-display-buffer))
(add-to-list 'window-persistent-parameters '(my-pi-panel . writable))

(defun my-pi-toggle ()
  "Focus the selected project chat, or hide its panel."
  (interactive)
  (if (window-parameter nil 'my-pi-panel)
      (let ((return my-pi-return-window))
        (setq my-pi-width (/ (float (window-total-width)) (frame-width)))
        (delete-window)
        (when (window-live-p return) (select-window return)))
    (let* ((root (my-pi-history-root
                  (or (alist-get 'my-project-root (tab-bar--current-tab))
                      (when-let* ((project (project-current))) (project-root project)) default-directory)))
           (id (my-pi-history-selected root)))
      (my-pi-history-recover root)
      (if (and id (my-pi-history-get id)) (my-pi-open-chat root id)
        (my-pi-new-chat root)))))

(defun my-pi-after-select (previous tab)
  "Remove stale or inherited Pi panels when selecting project TAB."
  (when (and (not (equal (alist-get 'my-project-root previous)
                         (alist-get 'my-project-root tab)))
             (boundp 'my-pi-history-frame) (frame-live-p my-pi-history-frame))
    (my-pi-history-close))
  (dolist (window (window-list nil 'nomini))
    (when (window-parameter window 'my-pi-panel)
      (with-current-buffer (window-buffer window)
        (unless (equal my-pi-root (alist-get 'my-project-root tab))
          (delete-window window))))))

(add-hook 'tab-bar-tab-post-select-functions #'my-pi-after-select)
(defun my-pi-save-session (save-function &rest args)
  "Ignore temporary tab selections made by SAVE-FUNCTION."
  (let ((tab-bar-tab-post-select-functions
         (remq #'my-pi-after-select tab-bar-tab-post-select-functions)))
    (apply save-function args)))
(dolist (save-function '(tabspaces-save-session tabspaces-save-all-project-sessions
                        tabspaces-save-non-project-tabs))
  (advice-add save-function :around #'my-pi-save-session))
(global-set-key (kbd "C-c a") #'my-pi-toggle)
(define-key agent-shell-mode-map (kbd "C-c a") #'my-pi-toggle)

;; A visible divider gives the mouse a wider resize target.
(setq window-divider-default-right-width 5
      window-divider-default-places 'right-only)
(window-divider-mode 1)
(set-face-attribute 'window-divider nil :background "#73726b" :foreground "#73726b")
(dolist (face '(window-divider-first-pixel window-divider-last-pixel))
  (set-face-attribute face nil :background "#999891" :foreground "#999891"))


(defvar my-pi-sessions (make-hash-table :test #'equal))
(defvar my-pi-refreshes (make-hash-table :test #'equal))
(defvar-local my-pi-subscription nil)
(defvar-local my-pi-header " Chats · Starting…")
(defvar-local my-pi-rendered nil)
(defvar-local my-pi-jump-message nil)

(defun my-pi-live-p (buffer)
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (when-let* ((client (map-elt (agent-shell--state) :client))
                     (process (map-elt client :process)))
           (process-live-p process)))))

(defun my-pi-history-refresh (root &optional done)
  (my-pi-history-cancel (gethash root my-pi-refreshes))
  (puthash root
    (my-pi-history-search root ""
      (lambda (result)
        (if (plist-get result :error) (message "Pi history: %s" (plist-get result :error))
          (when (plist-get result :warnings) (message "Pi history: %s" (string-join (plist-get result :warnings) "; ")))
          (my-pi-history-recover root)
          (my-pi-history-resume-deletions root)
          (my-pi-update-headers)
          (when done (funcall done)))))
    my-pi-refreshes))

(defun my-pi-header-button (text help action)
  (propertize text 'mouse-face 'mode-line-highlight 'help-echo help
    'local-map (let ((map (make-sparse-keymap)))
                 (define-key map [header-line down-mouse-1] #'ignore)
                 (define-key map [header-line mouse-1] action) map)))
(defun my-pi-update-headers ()
  (dolist (buffer (agent-shell-buffers))
    (with-current-buffer buffer
      (when my-pi-root
        (let* ((root my-pi-root) (chats (my-pi-history-list root))
               (running (cl-count-if (lambda (c) (and (member (plist-get c :turn_state) '("running" "needs-input"))
                                                     (my-pi-live-p (gethash (plist-get c :id) my-pi-sessions)))) chats))
               (unread (cl-count-if (lambda (c) (plist-get c :unread)) chats)))
          (setq my-pi-header
                (concat
                 (my-pi-header-button (format " Chats · %s running · %s unread " running unread) "Search this project's chats"
                                     (lambda () (interactive) (my-pi-history-show root)))
                 (my-pi-header-button " + " "New chat" (lambda () (interactive) (my-pi-new-chat root)))
                 (my-pi-header-button " ⋯ " "Chat history actions" (lambda () (interactive) (my-pi-history-menu root)))))
          (setq-local header-line-format '(:eval (list my-pi-header)))))))
  (force-mode-line-update t))
(defun my-pi-keep-header (&rest _)
  (when my-pi-root (setq-local header-line-format '(:eval (list my-pi-header)))))

(defun my-pi-on-event (event)
  (let* ((kind (map-elt event :event)) (data (map-elt event :data))
         (id (agent-shell-session-id)))
    (when (and id my-pi-root (or (not (eq kind 'clean-up)) (my-pi-history-get id)))
      (unless (my-pi-history-get id) (my-pi-history-register id my-pi-root))
      (puthash id (current-buffer) my-pi-sessions)
      (pcase kind
        ('init-finished
         (my-pi-history-select my-pi-root id)
         (my-pi-history-update id :owner_instance my-pi-history-instance)
         (my-pi-refresh-and-jump))
        ('session-title-changed
         (when-let* ((title (map-elt data :title))) (my-pi-history-update id :title title)))
        ('input-submitted
         (let* ((prompt (or (map-elt data :prompt) "")) (chat (my-pi-history-get id))
                (pos (save-excursion (goto-char (point-max)) (search-backward prompt nil t))))
           (when pos (puthash (format "input-%s" (float-time))
                             (list :role "user" :text prompt :marker (copy-marker pos)) my-pi-rendered))
           (my-pi-history-update id :turn_state "running" :owner_instance my-pi-history-instance :pending_since (my-pi-history-now))
           (unless (plist-get chat :first_prompt_at)
             (my-pi-history-update id :first_prompt_at (my-pi-history-now)
               :title (truncate-string-to-width (replace-regexp-in-string "[\n\r]+" " " prompt) 80 nil nil "…")))))
        ('permission-request (my-pi-history-update id :turn_state "needs-input"))
        ('permission-response (my-pi-history-update id :turn_state "running"))
        ('error (my-pi-history-update id :turn_state "error"))
        ('turn-complete
         (my-pi-history-update id :turn_state (if (equal (map-elt data :stop-reason) "cancelled") "interrupted" "idle") :pending_since nil)
         (my-pi-history-refresh my-pi-root))
        ('session-restored (my-pi-refresh-and-jump))
        ('clean-up
         (when (member (plist-get (my-pi-history-get id) :turn_state) '("running" "needs-input"))
           (my-pi-history-update id :turn_state "interrupted"))))
      (my-pi-update-headers))))

(defun my-pi-refresh-and-jump ()
  (let ((buffer (current-buffer)))
    (my-pi-history-refresh my-pi-root
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when my-pi-jump-message
              (let ((message-id my-pi-jump-message))
                (setq my-pi-jump-message nil)
                (my-pi-goto-message message-id)))))))))

(defun my-pi-read-receipt ()
  (when (and my-pi-root (eq (current-buffer) (window-buffer (selected-window)))
             (>= (window-end (selected-window) t) (point-max)))
    (when-let* ((id (agent-shell-session-id)) (chat (my-pi-history-get id))
                ((plist-get chat :unread))
                ((not (member (plist-get chat :turn_state) '("running" "needs-input")))))
      (my-pi-history-update id :read_reply_id (plist-get chat :last_reply_id)))))

(defun my-pi-attach ()
  (when (and my-pi-root (map-elt (agent-shell--state) :client))
    (unless my-pi-rendered (setq my-pi-rendered (make-hash-table :test #'equal)))
    (unless my-pi-subscription
      (setq my-pi-subscription
            (agent-shell-subscribe-to :shell-buffer (current-buffer) :on-event #'my-pi-on-event)))
    (add-hook 'post-command-hook #'my-pi-read-receipt nil t)
    (when-let* ((id (agent-shell-session-id)))
      (puthash id (current-buffer) my-pi-sessions)
      (my-pi-history-register id my-pi-root)
      (unless (my-pi-history-selected my-pi-root) (my-pi-history-select my-pi-root id))
      (when-let* ((title (map-nested-elt (agent-shell--state) '(:session :title))))
        (my-pi-history-update id :title title)))
    (my-pi-update-headers)))

(defun my-pi-start-chat (root &optional id message-id)
  (let* ((root (my-pi-history-root root)) (default-directory root)
         (source (if (window-parameter nil 'my-pi-panel) my-pi-return-window (selected-window))) (agent-shell-cwd-function (lambda () root))
         (agent-shell-session-strategy 'new))
    (when (file-remote-p root) (user-error "Pi supports local projects"))
    (unless (file-executable-p (car agent-shell-pi-acp-command)) (user-error "Run make pi-acp first"))
    (let ((buffer (agent-shell-start :config (agent-shell-pi-make-agent-config) :session-id id)))
      (with-current-buffer buffer
        (setq my-pi-root root my-pi-return-window source my-pi-jump-message message-id)
        (my-pi-attach))
      (select-window (my-pi-display-buffer buffer nil))
      buffer)))
(defun my-pi-new-chat (root)
  (interactive (list (or my-pi-root (alist-get 'my-project-root (tab-bar--current-tab)) default-directory)))
  (my-pi-start-chat root))
(defun my-pi-open-chat (root id &optional message-id)
  (let ((chat (my-pi-history-get id)) (buffer (gethash id my-pi-sessions)))
    (unless (and chat (equal (my-pi-history-root root) (plist-get chat :project_root)))
      (user-error "Chat does not belong to this project"))
    (if (my-pi-live-p buffer)
        (progn (select-window (my-pi-display-buffer buffer nil))
               (my-pi-history-select root id)
               (when (and message-id (not (string-empty-p message-id))) (my-pi-goto-message message-id))
               buffer)
      (my-pi-start-chat root id (unless (equal message-id "") message-id)))))

(defun my-pi-record-rendered (key role text pos append)
  (when (and my-pi-root my-pi-rendered text pos)
    (let ((old (gethash key my-pi-rendered)))
      (puthash key (list :role role :text (if (and append old) (concat (plist-get old :text) text) text)
                        :marker (copy-marker pos)) my-pi-rendered))))
(defun my-pi-record-fragment (original model &rest args)
  (let ((range (apply original model args)))
    (when (string-suffix-p "agent_message_chunk" (or (map-elt model :block-id) ""))
      (my-pi-record-rendered (format "%s-%s" (map-elt model :namespace-id) (map-elt model :block-id))
       "assistant" (map-elt model :body) (map-nested-elt range '(:body :start)) (plist-get args :append)))
    range))
(defun my-pi-record-text (original &rest args)
  (let ((range (apply original args)))
    (when (string-suffix-p "user_message_chunk" (or (plist-get args :block-id) ""))
      (let* ((text (plist-get args :text)) (prompt (map-nested-elt (agent-shell--state) '(:agent-config :shell-prompt))))
        (when (and prompt (string-prefix-p prompt text)) (setq text (substring text (length prompt))))
        (my-pi-record-rendered (format "%s-%s" (plist-get args :namespace-id) (plist-get args :block-id))
         "user" text (map-nested-elt range '(:block :start)) (plist-get args :append))))
    range))
(defun my-pi-goto-message (message-id)
  "Resolve a persisted message against rendered entries in sequence."
  (let* ((id (agent-shell-session-id))
         (rows (sqlite-select (my-pi-history-open)
                "SELECT message_id,role,body FROM messages WHERE session_id=? AND message_id<>'' ORDER BY CAST(ordinal AS INTEGER)"
                (list id)))
         (rendered (sort (hash-table-values my-pi-rendered)
                         (lambda (a b) (< (plist-get a :marker) (plist-get b :marker)))))
         (forward (my-pi-align-message rows rendered message-id))
         (backward (my-pi-align-message (reverse rows) (reverse rendered) message-id)))
    ;; Both directions must identify the same occurrence; compaction can make
    ;; a retained duplicate ambiguous in a buffer that still shows old history.
    (if (not (and forward backward (= forward backward)))
        (message "Message is no longer uniquely identifiable in this conversation")
      (goto-char forward)
      (when (get-buffer-window (current-buffer)) (set-window-point (get-buffer-window (current-buffer)) forward))
      (recenter))))

(defun my-pi-align-message (rows rendered message-id)
  (let (found failed)
    (dolist (row rows)
      (while (and rendered
                  (not (and (equal (nth 1 row) (plist-get (car rendered) :role))
                            (equal (string-trim (nth 2 row)) (string-trim (plist-get (car rendered) :text))))))
        (setq rendered (cdr rendered)))
      (if (not rendered) (setq failed t)
        (when (equal message-id (car row)) (setq found (plist-get (car rendered) :marker)))
        (setq rendered (cdr rendered))))
    (unless failed found)))

(defun my-pi-history-after-delete (root)
  (let ((window (cl-find-if (lambda (w) (and (window-parameter w 'my-pi-panel)
                    (equal root (buffer-local-value 'my-pi-root (window-buffer w))))) (window-list))))
    (when window
      (let ((current (with-current-buffer (window-buffer window)
                       (and (derived-mode-p 'agent-shell-mode) (agent-shell-session-id)))))
        (unless (and current (my-pi-history-get current))
          (select-window window)
          (if-let* ((chat (car (my-pi-history-list root))))
              (my-pi-open-chat root (plist-get chat :id))
            (let ((buffer (get-buffer-create (format " *Pi empty: %s*" root))))
              (with-current-buffer buffer
                (special-mode)
                (setq-local my-pi-root root default-directory root tab-line-format nil mode-line-format nil)
                (let ((inhibit-read-only t))
                  (erase-buffer) (insert "No chats yet\n\n")
                  (insert-text-button "New chat" 'action (lambda (_) (my-pi-new-chat root))))
                (setq my-pi-header
                  (concat (my-pi-header-button " Chats · 0 running · 0 unread " "Project history" (lambda () (interactive) (my-pi-history-show root)))
                          (my-pi-header-button " + " "New chat" (lambda () (interactive) (my-pi-new-chat root)))))
                (setq-local header-line-format '(:eval (list my-pi-header))))
              (set-window-buffer window buffer))))))))

(advice-add 'agent-shell-ui-update-fragment :around #'my-pi-record-fragment)
(advice-add 'agent-shell-ui-update-text :around #'my-pi-record-text)
(advice-add 'agent-shell--update-header-and-mode-line :after #'my-pi-keep-header)
(add-hook 'agent-shell-mode-hook #'my-pi-attach)
(add-hook 'my-pi-history-change-hook #'my-pi-update-headers)

(load (expand-file-name "pi-history-ui.el" (file-name-directory load-file-name)) nil t)
(dolist (buffer (agent-shell-buffers))
  (with-current-buffer buffer
    (my-pi-setup-mode-line)
    (my-pi-attach)))
(provide 'my-pi-panel)

