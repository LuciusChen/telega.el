;;; telega-topic.el --- Forums support for telega  -*- lexical-binding: t -*-

;; Copyright (C) 2022 by Zajcev Evgeny.

;; Author: Zajcev Evgeny <zevlg@yandex.ru>
;; Created: Sun Nov  6 02:12:07 2022
;; Keywords:

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; ellit-org: commentary
;;
;; Telegram allows creating forums with multiple distinct topics.  Use
;; {{{kbd(M-x telega-chat-create RET forum RET)}}} to create forums.
;; 
;; NOTE: forums and topics are not fully supported by =telega= at moment.

;;; Code:
(require 'telega-core)

(declare-function telega-chat--mark-dirty "telega-tdlib-events" (chat &optional event))
(declare-function telega-topic-button-action "telega-root" (topic))

(defvar telega-topic--default-icons nil
  "Cached list of topic icons which can be used by all users.")

(defun telega-topic-icon-custom-emoji-id (topic)
  "Return custom emoji id for the TOPIC."
  (let ((cid (telega--tl-get topic :info :icon :custom_emoji_id)))
    (unless (equal "0" cid)
      cid)))

(defun telega-topic-avatar-image (topic &optional cheight)
  "Return avatar image for the TOPIC."
  (if-let* ((cid (telega-topic-icon-custom-emoji-id topic))
            (sticker (telega-custom-emoji-get cid)))
      (telega-sticker--image sticker)

    ;; Fallback to svg icon
    (let* ((cheight (or cheight 1))
           (xh (telega-chars-xheight 1))
           (xw (telega-chars-xwidth 2))
           (svg (telega-svg-create xw xh))
           (title (telega-tl-str (plist-get topic :info) :name))
           (general-p (telega-topic-match-p topic 'is-general))
           (badge (if general-p "#" (substring title 0 1)))
           (font-size (if general-p xh (/ xh 2))))
      (unless general-p
        ;; Draw topic icon
        (let* ((palette (telega-palette-by-color-id
                         (% (telega-topic-msg-thread-id topic) 7)))
               (c1 (telega-color-name-as-hex-2digits
                    (or (telega-palette-attr palette :background) "gray75")))
               (c2 (telega-color-name-as-hex-2digits
                    (or (telega-palette-attr palette :foreground) "gray25")))
               (co (telega-color-name-as-hex-2digits
                    (or (telega-palette-attr palette :outline) c2))))
          (svg-gradient svg "cgrad" 'linear (list (cons 0 c1) (cons xh c2)))
          (telega-svg-forum-topic-icon svg xw
            :stroke-width (/ xh 20.0)
            :stroke-color co
            :gradient "cgrad")))

      (svg-text svg badge
                :font-size font-size
                :font-weight "bold"
                :fill (if general-p
                          (telega-color-name-as-hex-2digits
                           (face-foreground 'telega-shadow nil t))
                        "white")
                :font-family "monospace"
                :x "50%"
                :text-anchor "middle"
                ;; XXX insane Y calculation
                :y (+ (/ font-size 3) (/ xw 2)))

      (telega-svg-image svg
        :scale 1.0
        :width (telega-cw-width (* 2 cheight))
        :max-height (telega-ch-height cheight)
        :ascent 'center
        :mask 'heuristic))))

(defun telega-topic-msg-thread-id (topic)
  (telega--tl-get topic :info :message_thread_id))

(defun telega-topic-notification-setting (topic setting)
  (telega-chat-notification-setting (telega-topic-chat topic) setting topic))

(defun telega-topic-muted-p (topic)
  "Return non-nil if TOPIC is muted."
  (> (telega-topic-notification-setting topic :mute_for) 0))

(defun telega-chat-topics (chat &optional force-update-p)
  "Get CHAT's topics.
If FORCE-UPDATE-P is specified, then refetch topics from Telegram server."
  ;; NOTE: since TDLib (1.8.25) does not yet have update events for
  ;; the topics, we refetch topics when `TAB' is pressed on the forum
  ;; chat in the rootbuf
  (let ((topics (gethash (plist-get chat :id) telega--chat-topics)))
    (when force-update-p
      (let ((forum-topics (telega--getForumTopics chat "")))
        ;; NOTE: `telega--getForumTopics' might return partial list of
        ;; topics
        (seq-doseq (topic (plist-get forum-topics :topics))
          (telega-chat--topic-ensure chat topic))))
    topics))

(defun telega-topic-get (chat msg-thread-id)
  "Get CHAT's topic by THREAD-ID."
  (let ((topics (telega-chat-topics chat)))
    (cl-find msg-thread-id topics :key #'telega-topic-msg-thread-id)))

(defun telega-chat--topic-ensure (chat topic)
  "Ensure TOPIC for CHAT is stored in the `telega--chat-topics'."
  (if-let ((existing-topic
            (telega-topic-get chat (telega-topic-msg-thread-id topic))))
      ;; Update topic inplace
      (setcdr existing-topic (cdr topic))
    (puthash (plist-get chat :id)
             (append (telega-chat-topics chat) (list topic))
             telega--chat-topics))

  ;; Store back reference to chat in the `:telega-chat' property
  (plist-put topic :telega-chat chat)
  topic)

(defun telega-topic-chat (topic)
  "Return chat for the TOPIC."
  (plist-get topic :telega-chat))

(defun telega-chat--topics-icons-fetch (chat topics)
  "Asynchronously fetch icons for the list of the TOPICS."
  (when-let ((custom-emoji-ids
              ;; NOTE: Fetch only uncached custom emojis
              (seq-remove (lambda (cid)
                            (or (equal "0" cid)
                                (telega-custom-emoji-get cid)))
                          (mapcar (telega--tl-prop :info :icon :custom_emoji_id)
                                  topics))))
    (telega--getCustomEmojiStickers custom-emoji-ids
      (lambda (stickers)
        (seq-doseq (sticker stickers)
          (telega-custom-emoji--ensure sticker))

        (telega-chat--mark-dirty chat)))
    ))

(defun telega-chat--topics-fetch (chat)
  "Asynchronously fetch topics for the CHAT."
  (telega--getForumTopics chat ""
    :callback (lambda (reply)
                (plist-put chat :telega_topics_count
                           (plist-get reply :total_count))

                (let ((topics (plist-get reply :topics)))
                  (telega-chat--topics-icons-fetch chat topics)
                  (seq-doseq (topic topics)
                    (telega-chat--topic-ensure chat topic)))

                (telega-chat--mark-dirty chat)))
  )

(defun telega-msg-topic (msg &optional _offline-p)
  "Return topic for the message MSG."
  (when (telega-msg-match-p msg 'is-topic)
    (telega-topic-get (telega-msg-chat msg)
                      (plist-get msg :message_thread_id))))

(defun telega-topic-at (&optional pos)
  "Return topic at point POS."
  (let ((button (button-at (or pos (point)))))
    (when (and button (eq (button-type button) 'telega-topic))
      (button-get button :value))))

(defun telega-topic-goto (topic &optional start-msg-id)
  "Open TOPIC in a chatbuf.
If START-MSG-ID is specified, jump to the this message in the topic."
  (let* ((topic-chat (telega-topic-chat topic))
         (buffer (telega-chatbuf--get-create topic-chat :no-history)))
    ;; NOTE: pop to buffer after starting filtering by topic, to make
    ;; `telega-root--keep-cursor-at-chat' do the job for keeping
    ;; cursor at topic position
    (with-current-buffer buffer
      (unless (eq topic (telega-chatbuf--thread-topic))
        (telega-chatbuf-filter-by-topic topic start-msg-id)))

    (telega-chat--pop-to-buffer topic-chat :no-history)))

(defun telega-describe-topic (topic)
  "Show info about TOPIC."
  (interactive (list (telega-topic-at (point))))
  (with-telega-help-win "*Telegram Topic Info*"
    (let ((chat (telega-topic-chat topic))
          (topic-info (plist-get topic :info)))
      (telega-ins-describe-item (telega-i18n "lng_forum_topic_title")
        (telega-ins--with-face 'telega-shadow
          (telega-ins (telega-symbol 'topic))
          (telega-ins--topic-title topic 'with-icon))
        (telega-ins " ")
        ;; TODO: [Open] button
        ;; (telega-ins--box-button "Open"
        ;;                     )
        )
      (telega-ins-describe-item "Chat"
        (telega-button--insert 'telega-chat chat
          :inserter #'telega-ins--chat
          :action #'telega-chat-button-action))
      (telega-ins-describe-item "Created"
        (telega-ins--date (plist-get topic-info :creation_date) 'date-time))
      (telega-ins-describe-item (telega-i18n "lng_topic_author_badge")
        (telega-ins--msg-sender
            (telega-msg-sender (plist-get topic-info :creator_id))
          :with-avatar-p t
          :with-username-p t
          :with-brackets-p t))
      (telega-ins-describe-item "Last-Read-Outbox"
        (telega-ins-fmt "%S" (plist-get topic :last_read_outbox_message_id)))
      (telega-ins-describe-item "Message-Thread-Id"
        (telega-ins-fmt "%S" (plist-get topic-info :message_thread_id)))
      
      ;; TODO: more fields

      (when (and (listp telega-debug) (memq 'info telega-debug))
        (let ((print-length nil))
          (telega-ins "\n---DEBUG---\n")
          (telega-ins-fmt "TopicSexp: (telega-topic-get (telega-chat-get %d) %d)\n"
            (plist-get chat :id) (plist-get topic-info :message_thread_id))
          ))
      )))

(defun telega-msg-show-topic-info (msg)
  "Show MSG's topic info."
  (interactive (list (telega-msg-for-interactive)))
  (telega-describe-topic (telega-msg-topic msg)))


;;; Topic button
(defvar telega-topic-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map (kbd "i") 'telega-describe-topic)
    (define-key map (kbd "h") 'telega-describe-topic)
    map)
  "The key map for telega topic buttons.")

(define-button-type 'telega-topic
  :supertype 'telega
  :inserter telega-inserter-for-topic-button
  :action #'telega-topic-button-action
  'keymap telega-topic-button-map)

(provide 'telega-topic)

;;; telega-topic.el ends here
