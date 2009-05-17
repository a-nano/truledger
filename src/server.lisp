; -*- mode: lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; The Trubanc server
;;;

(in-package :trubanc-server)

(defun make-server (dir passphrase &key (bankname "") (bankurl ""))
  "Create a Trubanc server instance."
  (let ((db (make-fsdb dir)))
    (make-instance 'server
                   :db db
                   :passphrase passphrase
                   :bankname bankname
                   :bankurl bankurl)))

(defclass server ()
  ((db :type db
       :initarg :db
       :accessor db)
   (parser :type parser
           :initarg :parser
           :accessor parser)
   (timestamp :type timestamp
              :initform (make-instance 'timestamp)
              :accessor timestamp)
   (pubkeydb :type db
             :accessor pubkeydb)
   (bankname :type (or string null)
             :initarg :bankname
             :initform "A Random Trubanc"
             :accessor bankname)
   (bankurl :type (or string null)
            :initarg :bankurl
            :initform nil
            :accessor bankurl)
   (tokenid :type string
            :accessor tokenid)
   (regfee :type string
           :initarg :regfee
           :initform "10"
           :accessor regfee)
   (tranfee :type string
            :initarg :tranfee
            :initform "2"
            :accessor tranfee)
   (privkey :accessor privkey)
   (bankid :type (or string null)
           :initform nil
           :accessor bankid)
   (always-verify-sigs-p :type boolean
                         :initarg :always-verify-sigs-p
                         :initform t
                         :accessor always-verify-sigs-p)
   (debugmsgs-p :type boolean           ;of strings
                :initform nil
                :accessor debugmsgs-p)
   (debugstr :type string
             :initform ""
             :accessor debugstr)))

(defmethod initialize-instance :after ((server server) &key db passphrase)
  (let ((pubkeydb (db-subdir db $PUBKEY)))
    (setf (pubkeydb server) pubkeydb
          (parser server) (make-instance
                           'parser
                           :keydb pubkeydb
                           :bank-getter (lambda () (bankid server))
                           :always-verify-sigs-p (always-verify-sigs-p server)))
    (setup-db server passphrase)))

(defmethod gettime ((server server))
  (let* ((db (db server)))
    (with-db-lock (db $TIME)
      (let ((res (next (timestamp server) (db-get db $TIME))))
        (db-put db $TIME res)
        res))))

(defun account-dir (id)
  (strcat $ACCOUNT "/" id  "/"))

(defun acct-last-key (id)
  (strcat (account-dir id) $LAST))

(defmethod get-acct-last ((server server) id)
  (db-get (db server) (acct-last-key id)))

(defun acct-req-key (id)
  (strcat (account-dir id) $REQ))

(defmethod get-acct-req ((server server) id)
  (db-get (db server) (acct-req-key id)))

(defun acct-time-key (id)
  (strcat (account-dir id) $TIME))

(defun balance-key (id)
  (strcat (account-dir id) $BALANCE))

(defun acct-balance-key (id &optional (acct $MAIN))
  (strcat (balance-key id) "/" acct))

(defun asset-balance-key (id asset &optional (acct $MAIN))
  (strcat (acct-balance-key id acct) "/" asset))

(defun fraction-balance-key (id asset)
  (strcat (account-dir id) $FRACTION "/" asset))

(defmethod asset-balance ((server server) id asset &optional (acct "main"))
  (let* ((key (asset-balance-key id asset acct))
         (msg (db-get (db server) key)))
    (if (not msg)
        "0"
        (unpack-bankmsg server msg $ATBALANCE $BALANCE $AMOUNT))))

(defun outbox-key (id)
  (strcat (account-dir id) $OUTBOX))

(defun outbox-hash-key (id)
  (strcat (account-dir id) $OUTBOXHASH))

(defun inbox-key (id)
  (strcat (account-dir id) $INBOX))

(defmethod storage-info ((server server) id assetid)
  "Get the values necessary to compute the storage fee.
   Inputs:
    ID - the user ID
    ASSETID - the asset ID
   Return values:
    1) storage fee percent
    2) the fraction balance for ID/ASSETID
    3) the time of the fraction
    4) the ID of the asset issuer"
  (let* ((parser (parser server))
         (db (db server))
         (msg (db-get db $ASSET assetid)))
    (unless msg
      (error "Uknown asset: ~%" assetid))
    (let* ((reqs (parse parser msg))
           (req (elt reqs 1)))
      (unless req (return-from storage-info nil))

      (let ((args (match-pattern parser req)))
        (unless (equal (getarg $REQUEST args) $ATSTORAGE)
          (return-from storage-info nil))
        (setq req (getarg $MSG args)
              args (match-pattern parser req))
        (unless (equal (getarg $REQUEST args) $STORAGE)
          (return-from storage-info nil))
        (let ((issuer (getarg $CUSTOMER args))
              (percent (getarg $PERCENT args)))
          (let* ((fraction nil)
                 (fractime nil)
                 (key (fraction-balance-key id assetid))
                 (msg (db-get db key)))
            (when msg
              (setq args (unpack-bankmsg server msg $ATFRACTION $FRACTION)
                    fraction (getarg $AMOUNT args)
                    fractime (getarg $TIME args)))
            (values percent fraction fractime issuer)))))))

(defun storage-fee-key (id &optional assetid)
  (let ((res (strcat (account-dir id) $STORAGEFEE)))
    (if assetid
        (strcat res "/" assetid)
        res)))

(defun outbox-dir (id)
  (strcat (account-dir id) $OUTBOX))

(defmethod unpacker ((server server))
  #'(lambda (msg) (unpack-bankmsg server msg)))

(defmethod outbox-hash ((server server) id &optional newitem removed-items)
  (let ((db (db server)))
    (dirhash db (outbox-key id) (unpacker server) newitem removed-items)))

(defmethod outbox-hash-msg ((server server) id)
  (multiple-value-bind (hash count) (outbox-hash server id)
    (bankmsg server
             $OUTBOXHASH
             (bankid server)
             (get-acct-last server id)
             count
             hash)))

(defun balance-hash-key (id)
  (strcat (account-dir id) $BALANCEHASH))

(defmethod is-asset-p ((server server) assetid)
  "Returns the message defining ASSETID, or NIL, if there isn't one."
  (db-get (db server) $ASSET assetid))

(defmethod lookup-asset ((server server) assetid)
  (let ((asset (is-asset-p server assetid)))
    (when asset
      (let ((res (unpack-bankmsg server asset $ATASSET $ASSET)))
        (let* ((reqs (getarg $UNPACK-REQS-KEY res))
               (req1 (and (> (length reqs) 1) (elt reqs 1))))
          (when req1
            (let ((args (match-pattern (parser server) req1)))
              (setf (getarg $PERCENT res) (getarg $PERCENT args)))))
        res))))

(defmethod lookup-asset-name ((server server) assetid)
  (let ((assetreq (lookup-asset server assetid)))
    (and assetreq
         (getarg $ASSETNAME assetreq))))

;; More restrictive than Lisp's alphanumericp
(defun is-alphanumeric-p (char)
  (let ((code (char-code char)))
    (or (and (>= code #.(char-code #\0)) (<= code #.(char-code #\9)))
        (and (>= code #.(char-code #\a)) (<= code #.(char-code #\z)))
        (and (>= code #.(char-code #\A)) (<= code #.(char-code #\Z))))))

(defun is-alphanumeric-or-space-p (char)
  (or (eql char #\space)
      (is-alphanumeric-p char)))

(defun is-numeric-p (string &optional integer-p)
  (loop
     with firstp = t
     with sawdotp = integer-p
     for chr across string
     for code = (char-code chr)
     do
     (cond ((eql chr #\-)
            (unless firstp (return nil)))
           ((eql chr #\.)
            (when sawdotp (return nil))
            (setq sawdotp t))
           (t (unless (and (>= code #.(char-code #\0))
                           (<= code #.(char-code #\9)))
                (return nil))))
     (setq firstp nil)
     finally (return t)))

(defun is-acct-name-p (acct)
  (and (stringp acct)
       (every #'is-alphanumeric-p acct)))

(defun pubkey-id (pubkey)
  (sha1 (trim pubkey)))

(defun privkey-id (privkey)
  (with-rsa-private-key (key privkey)
    (pubkey-id (encode-rsa-public-key key))))

(defmethod unpack-bank-param ((server server) type &optional (key type))
  "Unpack wrapped initialization parameter."
  (unpack-bankmsg server (db-get (db server) type) type nil key))

(defun signmsg (privkey msg)
  (let ((sig (sign msg privkey)))
    (strcat msg #.(format nil ":~%") sig)))

(defmethod banksign ((server server) msg)
  "Bank sign a message."
  (signmsg (privkey server) msg))

(defmethod bankmsg ((server server) &rest req)
  "Make a bank signed message from the args."
  (banksign server (apply #'makemsg (parser server) (bankid server) req)))

(defun shorten-failmsg-msg (msg)
  (if (> (length msg) 1024)
      (strcat (subseq msg 0 1021) "...")
      msg))

(defmethod failmsg ((server server) &rest req)
  (when (stringp (car req))
    (setf (car req) (shorten-failmsg-msg (car req))))
  (banksign server (apply #'simple-makemsg (bankid server) $FAILED req)))


(defmethod unpack-bankmsg ((server server) msg &optional type subtype idx)
  "Reverse the bankmsg() function, optionally picking one field to return."
  (let* ((bankid (bankid server))
         (parser (parser server))
         (reqs (parse parser msg))
         (req (elt reqs 0))
         (args (match-pattern parser req)))
    (when (and bankid (not (equal (getarg $CUSTOMER args) bankid)))
      (error "Bankmsg not from bank"))
    (when (and type (not (equal (getarg $REQUEST args) type)))
      (error "Bankmsg wasn't of type: ~s" type))
    (cond ((not subtype)
           (cond (idx
                  (or (getarg idx args)
                      (error "No arg in bankmsg: ~s" idx)))
                 (t (setf (getarg $UNPACK-REQS-KEY args) reqs) ; save parse results
                    args)))
          (t (setq req (getarg $MSG args)) ;this is already parsed
             (unless req
               (error "No wrapped message"))
             (setq args (match-pattern parser req))
             (when (and subtype
                        (not (eq subtype t))
                        (not (equal (getarg $REQUEST args) subtype)))
               (error "Wrapped message wasn't of type: ~s" subtype))
             (cond (idx
                    (or (getarg idx args)
                        (error "No arg with idx: ~s" idx)))
                   (t (setf (getarg $UNPACK-REQS-KEY args) reqs) ; save parse results
                      args))))))

(defmethod setup-db ((server server) passphrase)
  "Initialize the database, if it needs initializing."
  (let ((db (db server)))
    (if (db-get db $PRIVKEY)
        (let* ((privkey (decode-rsa-private-key (db-get db $PRIVKEY) passphrase))
               (pubkey (encode-rsa-public-key privkey))
               (bankid (pubkey-id pubkey)))
          (setf (privkey server) privkey
                (bankid server) bankid
                (bankurl server) (db-get db $BANKURL)
                (tokenid server) (unpack-bank-param server $TOKENID)
                (regfee server) (unpack-bank-param server $REGFEE $AMOUNT)
                (tranfee server) (unpack-bank-param server $TRANFEE $AMOUNT)))
        ;; http://www.rsa.com/rsalabs/node.asp?id=2004 recommends that 3072-bit
        ;; RSA keys are equivalent to 128-bit symmetric keys, and they should be
        ;; secure past 2031.
        (let* ((privkey (rsa-generate-key 3072))
               (privkey-text (encode-rsa-private-key privkey passphrase))
               (pubkey (encode-rsa-public-key privkey))
               (bankid (pubkey-id pubkey))
               (bankname (bankname server))
               (ut "Usage Tokens")
               (token-name (if bankname (strcat bankname " " ut) ut))
               (zero "0")
               (tokenid (assetid bankid zero zero token-name)))
          (db-put db $PRIVKEY privkey-text)
          (setf (privkey server) privkey
                (bankid server) bankid)
          (db-put db $TIME zero)
          (db-put db $BANKID (bankmsg server $BANKID bankid))
          (db-put db $BANKURL (bankurl server))
          (setf (db-get db $PUBKEY bankid) pubkey)
          (setf (db-get db $PUBKEYSIG bankid)
                (bankmsg server $ATREGISTER
                         (bankmsg server $REGISTER
                                  bankid
                                  (strcat #.(format nil "~%") pubkey)
                                  bankname)))
          (setf (tokenid server) tokenid)
          (db-put db $TOKENID (bankmsg server $TOKENID tokenid))
          (setf (db-get db $ASSET tokenid)
                (bankmsg server $ATASSET
                         (bankmsg server $ASSET
                                  bankid tokenid zero zero token-name)))
          (db-put db $REGFEE
                  (bankmsg server $REGFEE bankid zero tokenid (regfee server)))
          (db-put db $TRANFEE
                  (bankmsg server $TRANFEE bankid zero tokenid (tranfee server)))
          (db-put db (acct-time-key bankid) zero)
          (db-put db (acct-last-key bankid) zero)
          (db-put db (acct-req-key bankid) zero)
          (db-put db (asset-balance-key bankid tokenid)
                  (bankmsg server $ATBALANCE
                           (bankmsg server $BALANCE
                                    bankid zero tokenid "-1")))))))

(defmethod scan-inbox ((server server) id)
  (loop
     with db = (db server)
     with inbox-key = (inbox-key id)
     with times = (db-contents db inbox-key)
     for time in times
     for item = (db-get db inbox-key time)
     when item
     collect item))

(defmethod signed-balance (server time asset amount &optional acct)
  (if acct
      (bankmsg server $BALANCE (bankid server) time asset amount acct)
      (bankmsg server $BALANCE (bankid server) time asset amount)))

(defmethod signed-spend ((server server) time id assetid amount &optional note)
  (let ((bankid (bankid server)))
    (if note
        (bankmsg server $SPEND bankid time id assetid amount note)
        (bankmsg server $SPEND bankid time id assetid amount))))

(defmethod enq-time ((server server) id)
  (let* ((db (db server))
         (time (gettime server))
         (key (acct-time-key id)))
    (with-db-lock (db key)
      (let ((q (db-get db key)))
        (if (not q)
            (setq q time)
            (dotcat q "," time))
        (db-put db key q)
        q))))

(defmethod deq-time (server id time)
  (let ((db (db server))
        (key (acct-time-key id)))
    (with-db-lock (db key)
      (let ((q (db-get db key))
            (res nil))
        (when q
          (let ((times (explode #\, q)))
            (dolist (v times)
              (when (equal v time)
                (setq res time
                      times (delete v times :test #'equal)
                      q (apply #'implode #\, times))
                (db-put db key q)))))
        (unless res (error "Timestamp not enqueued: ~s" time))
        (when (> (bccomp (get-universal-time) (bcadd time (* 10 60)))
                 0)
          (error "Timestamp too old: ~s" time))))
    time))

(defmethod add-to-bank-balance ((server server) assetid amount)
  "Add AMOUNT to the bank balance for ASSETID in the main account.
   Returns new balance, unless you add 0, then it returns nil."
  (let ((bankid (bankid server))
        (db (db server)))
    (unless (eql 0 (bccomp amount 0))
      (let ((key (asset-balance-key bankid assetid)))
        (with-db-lock (db key)
          (let* ((balmsg (db-get db key))
                 (balargs (unpack-bankmsg server balmsg $ATBALANCE $BALANCE)))
            (unless (or (null (getarg $ACCT balargs))
                        (equal $MAIN (getarg $ACCT balargs)))
              (error "Bank balance message not for main account"))
            (let* ((bal (getarg $AMOUNT balargs))
                   (newbal (bcadd bal amount))
                   (balsign (bccomp bal 0))
                   (newbalsign (bccomp newbal 0)))
              (when (or (and (>= balsign 0) (< newbalsign 0))
                        (and (< balsign 0) (>= newbalsign 0)))
                (error "Transaction would put bank out of balance."))
              ;; $BALANCE => `(,$BANKID ,$TIME ,$ASSET ,$AMOUNT (,$ACCT))
              (let ((msg (bankmsg server $ATBALANCE
                                  (bankmsg server $BALANCE
                                           bankid (gettime server) assetid newbal)))
                    (reqkey (acct-req-key bankid)))
                (db-put db key msg)
                ;; Make sure clients update the balance
                (db-put db reqkey (bcadd 1 (db-get db reqkey)))
                newbal))))))))

(defmethod checkreq (server args)
  (let* ((db (db server))
         (id (getarg $CUSTOMER args))
         (req (getarg $REQ args))
         (reqkey (acct-req-key id)))
    (with-db-lock (db reqkey)
      (let ((oldreq (db-get db reqkey)))
        (when (<= (bccomp req oldreq) 0)
          (error "New req <= old req"))
        (db-put db reqkey req)))))

(defstruct balance-state
  (acctbals (make-equal-hash))
  (bals (make-equal-hash))
  (tokens "0")
  (oldneg (make-equal-hash))
  (newneg (make-equal-hash))
  time
  (charges (make-equal-hash)))

(defmethod handle-balance-msg ((server server) id msg args state &optional
                               creating-asset)
  "Deal with an (<id>,balance,...) item from the customer for a
   spend or processinbox request.
   ID: the customer id
   MSG: the signed (<id>,balance,...) message, as a string
   ARGS: parser->parse(), then utility->match_pattern() output on balmsg
   STATE: a BALANCE-STATE instance.
     acctbals => hash: <acct> => (hash: <asset> => <msg>)
     bals => hash: <asset> => <amount>
     tokens => total new /account/<id>/balance/<acct>/<asset> files
     oldneg => hash: <asset> => <acct>, negative balances in current account
     newneg => hash: <asset> => <acct>, negative balances in updated account
     time => the transaction time"
  (unless (equal $BALANCE (getarg $REQUEST args))
    (error "Non-balance message passed to handle-balance-msg"))
  (let ((db (db server))
        (bankid (bankid server))
        (asset (getarg $ASSET args))
        (amount (getarg $AMOUNT args))
        (acct (or (getarg $ACCT args) $MAIN)))

    (when (and (or (not creating-asset) (not (equal asset creating-asset)))
               (not (is-asset-p server asset)))
      (error "Unknown asset id: ~s" asset))

    (unless (is-numeric-p amount)
      (error "Not a number: ~s" amount))

     (unless (is-acct-name-p acct)
       (error "<acct> may contain only letters and digits: ~s" acct))

     (let ((acct-hash (gethash acct (balance-state-acctbals state))))
       (unless acct-hash
         (setf (gethash acct (balance-state-acctbals state))
               (setq acct-hash (make-equal-hash))))
       (when (gethash asset acct-hash)
         (error "Duplicate acct/asset balance pair: ~s/~s" acct asset))

       (setf (gethash asset acct-hash) msg))

     (let ((bals (balance-state-bals state)))
       (setf (gethash asset bals) (bcsub (gethash asset bals 0) amount))

       (when (< (bccomp amount 0) 0)
         (when (gethash asset (balance-state-newneg state))
           (error "Multiple new negative balances for asset: ~s" asset))
         (setf (gethash asset (balance-state-newneg state)) acct))

       (let* ((asset-balance-key (asset-balance-key id asset acct))
              (acctmsg (db-get db asset-balance-key)))
         (if (not acctmsg)
             (unless (equal id bankid)
               (setf (balance-state-tokens state)
                     (bcadd (balance-state-tokens state) 1)))
             (let* ((acctargs (unpack-bankmsg server acctmsg $ATBALANCE $BALANCE))
                    (amount (getarg $AMOUNT acctargs)))
               (setf (gethash asset bals) (bcadd (gethash asset bals 0) amount))
               (when (< (bccomp amount 0) 0)
                 (when (gethash asset (balance-state-oldneg state))
                   (error "Account corrupted. ~
                           Multiple negative balances for asset: ~s"
                          asset))
                 (setf (gethash asset (balance-state-oldneg state)) acct))
               (compute-storage-charges server id state asset amount acctargs)))))))

(defstruct storage-info
  percent
  issuer
  fraction
  digits
  fee)

;; This is separate from handle-balance-msg mostly to get back some
;; horizontal text space. Nobody else calls it.
(defmethod compute-storage-charges ((server server) id state asset amount acctargs)
  "Compute storage charges as a list of storage-info instances"
  (let ((asset-info (gethash asset (balance-state-charges state))))
    (unless asset-info
      (unless (equal asset (tokenid server))
        (multiple-value-bind (percent fraction fractime issuer)
            (storage-info server id asset)
          (setq asset-info (make-storage-info :percent percent
                                              :issuer issuer
                                              :fraction fraction
                                              :fee 0))
          (setf (gethash asset (balance-state-charges state)) asset-info)
          (when percent
            (let ((digits (fraction-digits percent))
                  (time (balance-state-time state)))
              (when fraction
                (setf (storage-info-fee asset-info)
                      (storage-fee fraction fractime time percent digits)))
              (setf (storage-info-digits asset-info) digits))))))
    (when asset-info
      (let ((percent (storage-info-percent asset-info)))
        (when (and percent (> (bccomp amount 0) 0))
          (let* ((digits (storage-info-digits asset-info))
                 (accttime (getarg $TIME acctargs))
                 (time (balance-state-time state))
                 (fee (storage-fee amount accttime time percent digits)))
            (setf (storage-info-fee asset-info)
                  (bcadd (storage-info-fee asset-info) fee digits))))))))

(defmethod debugmsg ((server server) msg)
  (when (debugmsgs-p server)
    (setf (debugstr server) (strcat (debugstr server) msg))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;;  Request processing
;;;
 
(defvar *message-handlers* (make-equal-hash))

(defun get-message-handler (message)
  (or (gethash message *message-handlers*)
      (error "No message handler for ~s" message)))

(defun (setf get-message-handler) (value message)
  (setf (gethash message *message-handlers*) value))

(defmacro define-message-handler (name message (server args reqs) &body body)
  `(progn
     (setf (get-message-handler ,message) ',name)
     (defmethod ,name ((,server server) ,args ,reqs) ,@body)))

(define-message-handler do-bankid $BANKID (server inargs reqs)
  "Look up the bank's public key"
  (declare (ignore reqs))
  (let* ((db (db server))
         (bankid (bankid server))
         (coupon (getarg $COUPON inargs))
         (msg (db-get db $PUBKEYSIG bankid))
         (args (unpack-bankmsg server msg $ATREGISTER))
         (req (getarg $MSG args))
         (res (get-parsemsg req)))

    (when coupon
      ;; Validate a coupon number
      (let* ((coupon-number-hash (sha1 coupon))
             (key (strcat $COUPON "/" coupon-number-hash))
             (coupon (db-get db key)))
        (unless coupon
          (error "Coupon invalid or already redeemed"))
        (setq args (unpack-bankmsg server coupon $ATSPEND $SPEND))
        (let ((assetid (getarg $ASSET args))
              (amount (getarg $AMOUNT args))
              (id (getarg $CUSTOMER inargs)))
          (unless (db-get db (acct-last-key id))
            ;; Not already registered, coupon must be for usage tokens,
            ;; and must be big enough to register with
            (unless (equal assetid (tokenid server))
              (error "Coupon not for usage tokens"))
            (when (< (bccomp amount (bcadd (regfee server) 10)) 0)
              (error "It costs ~a + 10 usage tokens to register a new account."
                     (regfee server)))))
        (let ((msg (bankmsg server $COUPONNUMBERHASH coupon-number-hash)))
          (dotcat res "." msg))))

    res))

(define-message-handler do-id $ID (server args reqs)
  "Lookup a public key."
  (declare (ignore reqs))
  (or (db-get (db server) $PUBKEYSIG (getarg $ID args))
      (error "No such public key")))

(define-message-handler do-register $REGISTER (server args reqs)
  (let ((db (db server))
        (parser (parser server))
        (id (getarg $CUSTOMER args))
        (pubkey (getarg $PUBKEY args)))
    (when (db-get db (acct-last-key id))
      (error "Already registered"))
    (unless (equal (pubkey-id pubkey) id)
      (error "Pubkey doesn't match ID"))
    (when (> (pubkey-bits pubkey) 4096)
      (error "Key sizes larger than 4096 not allowed"))

    ;; Process included coupons
    (let ((reqargs-list nil))
      (dolist (req (cdr reqs))
        (let* ((reqargs (match-pattern parser req))
               (request (getarg $REQUEST reqargs)))
          (unless (equal request $COUPONENVELOPE)
            (error "Non-coupon request with register: ~s" request))
          (push reqargs reqargs-list)))

      (dolist (reqargs (nreverse reqargs-list))
        (do-couponenvelope-raw server reqargs id)))

    ;; Ensure we have enough tokens to register
    (let ((regfee (regfee server))
          (tokenid (tokenid server)))
      (when (> (bccomp regfee 0) 0)
        (let ((inbox (scan-inbox server id)))
          (dolist (inmsg inbox
                   (error "Insufficient asset tokens for registration fee"))
            (let ((inmsg-args (unpack-bankmsg server inmsg nil t)))
              (when (equal $SPEND (getarg $REQUEST inmsg-args))
                (let ((asset (getarg $ASSET inmsg-args))
                      (amount (getarg $AMOUNT inmsg-args)))
                  (when (and (equal asset tokenid) (> (bccomp amount regfee) 0))
                    (return))))))))

      ;; Create the account
      (let* ((msg (get-parsemsg (car reqs)))
             (res (bankmsg server $ATREGISTER msg))
             (time (gettime server)))
        (setf (db-get db $PUBKEY id) pubkey
              (db-get db $PUBKEYSIG id) res)
        ;; Post the debit for the registration fee
        (when (> (bccomp regfee 0)  0)
          (let* ((spendmsg (bankmsg server
                                    $INBOX
                                    time
                                    (signed-spend
                                     server time id tokenid (bcsub 0 regfee)
                                     "Registration fee"))))
            (setf (db-get db (inbox-key id) time) spendmsg)))
        ;; Mark the account as created
        (db-put db (acct-last-key id) "1")
        (db-put db (acct-req-key id) "0")
        res))))

(define-message-handler do-getreq $GETREQ (server args reqs)
  "Process a getreq message"
  (declare (ignore reqs))
  (let ((id (getarg $CUSTOMER args)))
    (bankmsg server $REQ id (db-get (db server) (acct-req-key id)))))

(define-message-handler do-gettime $GETTIME (server args reqs)
  "Process a time request."
  (declare (ignore reqs))
  (checkreq server args)
  (let ((db (db server))
        (id (getarg $CUSTOMER args)))
    (with-db-lock (db (acct-time-key id))
      (let ((time (gettime server)))
        (db-put db (acct-time-key id) time)
        (bankmsg server $TIME id time)))))

(define-message-handler do-getfees $GETFEES (server args reqs)
  (declare (ignore reqs))
  (checkreq server args)
  (let* ((db (db server))
         (regfee (db-get db $REGFEE))
         (tranfee (db-get db $TRANFEE)))
    (strcat regfee "." tranfee)))

(define-message-handler do-spend $SPEND (server args reqs)
  "Process a spend message."
  (with-verify-sigs-p ((parser server) nil)
    (let ((db (db server))
          (id (getarg $CUSTOMER args))
          res assetid issuer storagefee digits)
      (with-db-lock (db (acct-time-key id))
        (multiple-value-setq (res assetid issuer storagefee digits)
          (do-spend-internal server args reqs)))

      ;; This is outside the customer lock to avoid deadlock with the issuer account.
      (when storagefee
        (post-storage-fee server assetid issuer storagefee digits))

      res)))

(defmethod do-spend-internal ((server server) args reqs)
  "Do the work for a spend.
   Returns five values:
    res: The result message to be returned to the client
    assetid: the ID of the storage fee asset
    issuer: the issuer of the storage fee asset
    storagefee: the storage fee
    digits: the number of digits of precision for the storage fee"
  (let* ((db (db server))
         (bankid (bankid server))
         (parser (parser server))

         (id (getarg $CUSTOMER args))
         (time (getarg $TIME args))
         (id2 (getarg $ID args))
         (assetid (getarg $ASSET args))
         (amount (getarg $AMOUNT args))
         (note (getarg $NOTE args))
         (asset (lookup-asset server assetid)))

    ;; Burn the transaction, even if balances don't match.
    (deq-time server id time)

    (when (equal id2 bankid)
      (error "Spends to the bank are not allowed."))

    (unless asset
      (error "Unknown asset id: ~s" assetid))

    (unless (is-numeric-p amount)
      (error "Not a number: ~s" amount))

    ;; Make sure there are no inbox entries older than the highest
    ;; timestamp last read from the inbox
    (let ((inbox (scan-inbox server id))
          (last (get-acct-last server id)))
      (dolist (inmsg inbox)
        (let ((inmsg-args (unpack-bankmsg server inmsg)))
          (when (or (< (bccomp last 0) 0)
                    (<= (bccomp (getarg $TIME inmsg-args) last) 0))
            (error "Please process your inbox before doing a spend")))))

    (let* ((tokens (if (and (not (equal id id2))
                            (not (equal id bankid)))
                       (tranfee server)
                       "0"))
           (tokenid (tokenid server))
           (feemsg nil)
           (storagemsg nil)
           (storageamt nil)
           (fracmsg nil)
           (fracamt nil)
           (state (make-balance-state
                   :tokens tokens
                   :time time
                   :bals (make-equal-hash tokenid "0"
                                          assetid "0")))
           (outboxhash-req nil)
           (outboxhash-msg nil)
           (outboxhash nil)
           (outboxhash-cnt nil)
           (balancehash-req nil)
           (balancehash-msg nil)
           (balancehash nil)
           (balancehash-cnt nil))

      (unless (equal id id2)
        ;; No money changes hands on spends to yourself
        (setf (gethash assetid (balance-state-bals state))
              (bcsub 0 amount)))

      (loop
         for req in (cdr reqs)
         for reqargs = (match-pattern parser req)
         for reqid = (getarg $CUSTOMER reqargs)
         for request = (getarg $REQUEST reqargs)
         for reqtime = (getarg $TIME reqargs)
         for reqmsg = (get-parsemsg req)
         do
         (unless (equal reqtime time) (error "Timestamp mismatch"))
         (unless (equal reqid id) (error "ID mismatch"))
         (cond ((equal request $TRANFEE)
                (when feemsg (error "~s appeared multiple times" $TRANFEE))
                (let ((tranasset (getarg $ASSET reqargs))
                      (tranamt (getarg $AMOUNT reqargs)))
                  (unless (and (equal tranasset tokenid) (equal tranamt tokens))
                    (error "Mismatched tranfee asset or amount")))
                (setq feemsg (bankmsg server $ATTRANFEE reqmsg)))
               ((equal request $STORAGEFEE)
                (when storagemsg (error "~s appeared multiple times" $STORAGEFEE))
                (unless (equal assetid (getarg $ASSET reqargs))
                  (error "Storage fee asset id doesn't match spend"))
                (setq storageamt (getarg $AMOUNT reqargs)
                      storagemsg (bankmsg server $ATSTORAGEFEE reqmsg)))
               ((equal request $FRACTION)
                (when fracmsg (error "~s appeared multiple times" $FRACTION))
                (unless (equal assetid (getarg $ASSET reqargs))
                  (error "Fraction asset id doesn't match spend"))
                (setq fracamt (getarg $AMOUNT reqargs)
                      fracmsg (bankmsg server $ATFRACTION reqmsg)))
               ((equal request $BALANCE)
                (handle-balance-msg server id reqmsg reqargs state))
               ((equal request $OUTBOXHASH)
                (when outboxhash-req
                  (error "~s appeared multiple times" $OUTBOXHASH))
                (setq outboxhash-req req
                      outboxhash-msg reqmsg
                      outboxhash (getarg $HASH reqargs)
                      outboxhash-cnt (getarg $COUNT reqargs)))
               ((equal request $BALANCEHASH)
                (when balancehash-req
                  (error "~s appeared multiple times" $BALANCEHASH))
                (setq balancehash-req req
                      balancehash-msg reqmsg
                      balancehash (getarg $HASH reqargs)
                      balancehash-cnt (getarg $COUNT reqargs)))
               (t
                (error "~s not valid for spend. Only ~s, ~s, ~s, ~s, ~s, & ~s"
                       request
                       $TRANFEE $STORAGEFEE $FRACTION
                       $BALANCE $OUTBOXHASH $BALANCEHASH))))

      (let* ((acctbals (balance-state-acctbals state))
             (bals (balance-state-bals state))
             (tokens (balance-state-tokens state))
             (oldneg (balance-state-oldneg state))
             (newneg (balance-state-newneg state))
             (charges (balance-state-charges state))
             (storagefee nil)
             (assetinfo (gethash assetid charges))
             (percent (and assetinfo (storage-info-percent assetinfo)))
             issuer fraction digits)

    ;; Work the storage fee into the balances
    (when (and percent (not (eql (bccomp percent 0) 0)))
      (setq issuer (storage-info-issuer assetinfo)
            storagefee (storage-info-fee assetinfo)
            fraction (storage-info-fraction assetinfo)
            digits (storage-info-digits assetinfo))
      (let* ((bal (bcsub (gethash assetid bals 0) storagefee digits)))
        (multiple-value-setq (bal fraction) (normalize-balance bal fraction digits))
        (setf (gethash assetid bals) bal)
        (unless (eql 0 (bccomp fraction fracamt))
          (error "Fraction amount was: ~s, sb: ~s" fracamt fraction))
        (unless (eql 0 (bccomp storagefee storageamt))
          (error "Storage fee was: ~s, sb: ~s" storageamt storagefee))))

    (when (and (not storagefee) (or storagemsg fracmsg))
      (error "Storage or fraction included when no storage fee"))

    ;; tranfee must be included if there's a transaction fee
    (when (and (not (eql 0 (bccomp tokens 0)))
               (not feemsg)
               (not (equal id id2)))
      (error "~s  missing" $TRANFEE))

    (when (< (bccomp amount 0) 0)
      ;; Negative spend allowed only for switching issuer location
      (unless (gethash assetid oldneg)
        (error "Negative spend on asset for which you are not the issuer"))

      ;; Spending out the issuance.
      ;; Mark the new "acct" for the negative as being the spend itself.
      (unless (gethash assetid newneg)
        (setf (gethash assetid newneg) args)))

    ;; Check that we have exactly as many negative balances after the transaction
    ;; as we had before.
    (unless (eql (hash-table-count oldneg) (hash-table-count newneg))
      (error "Negative balance count not conserved"))
    (loop
       for old being the hash-keys of oldneg
       do
         (unless (gethash old newneg)
           (error "Negative balance assets not conserved")))

    ;; Charge the transaction and new balance file tokens
    (setf (gethash tokenid bals) (bcsub (gethash tokenid bals 0) tokens))

    (let ((errmsg nil))
      ;; Check that the balances in the spend message, match the current balance,
      ;; minus amount spent minus fees.
      (loop
         for balasset being the hash-key using (hash-value balamount) of bals
         do
           (unless (eql (bccomp balamount 0) 0)
             (let ((name (lookup-asset-name server balasset)))
               (setq errmsg (if errmsg (strcat errmsg ", ") ""))
               (dotcat errmsg name ": " balamount))))
      (when errmsg (error "Balance discrepancies: ~a" errmsg)))

    ;; Check outboxhash
    ;; outboxhash must be included, except on self spends
    (let ((spendmsg (get-parsemsg (car reqs))))
      (unless (or (equal id id2) (equal id bankid))
        (unless outboxhash-req
          (error "~s missing" $OUTBOXHASH))
        (multiple-value-bind (hash hashcnt) (outbox-hash server id spendmsg)
          (unless (and (equal outboxhash hash)
                       (eql 0 (bccomp outboxhash-cnt hashcnt)))
            (error "~s mismatch" $OUTBOXHASH))))

      ;; balancehash must be included, except on bank spends
      (unless (equal id bankid)
        (unless balancehash-req
          (error "~s missing" $BALANCEHASH))
        (multiple-value-bind (hash hashcnt)
            (balancehash db (unpacker server) (balance-key id) acctbals)
          (unless (and (equal balancehash hash)
                       (eql 0 (bccomp balancehash-cnt hashcnt)))
            (error "~s mismatch, hash sb: ~s, was: ~s, count sb: ~s, was: ~s"
                   $BALANCEHASH hash balancehash hashcnt balancehash-cnt))))

      ;; All's well with the world. Commit this puppy.
      ;; Eventually, the commit will be done as a second phase.
      (let* ((outbox-item (bankmsg server $ATSPEND spendmsg))
             (inbox-item nil)
             (res outbox-item)
             (newtime nil))
        (when feemsg
          (dotcat outbox-item "." feemsg)
          (setq res outbox-item))

        (cond ((not (equal id2 $COUPON))
               (unless (equal id id2)
                 (setq newtime (gettime server)
                       inbox-item (bankmsg server $INBOX newtime spendmsg))
                 (when feemsg
                   (dotcat inbox-item "." feemsg))))
              (t
               ;; If it's a coupon request, generate the coupon
               (let* ((coupon-number (random-id))
                      (bankurl (bankurl server))
                      (coupon
                       (if note
                           (bankmsg server $COUPON bankurl coupon-number
                                    assetid amount note)
                           (bankmsg server $COUPON bankurl coupon-number
                                    assetid amount)))
                      (coupon-number-hash (sha1 coupon-number)))
                 (setf (db-get db $COUPON coupon-number-hash) outbox-item)
                 (setq coupon
                       (bankmsg server $COUPONENVELOPE id
                                (pubkey-encrypt
                                 coupon (db-get (pubkeydb server) id))))
                 (dotcat res "." coupon)
                 (dotcat outbox-item "." coupon))))

        ;; Update balances
        (let ((balance-key (balance-key id)))
          (loop
             for acct being the hash-key using (hash-value balances) of acctbals
             for acctdir = (strcat balance-key "/" acct)
             do
               (loop
                  for balasset being the hash-key using (hash-value balance)
                  of balances
                  do
                    (setq balance (bankmsg server $ATBALANCE balance))
                    (dotcat res "." balance)
                    (setf (db-get db acctdir balasset) balance))))

        (when fracmsg
          (let ((key (fraction-balance-key id assetid)))
            (db-put db key fracmsg)
            (dotcat res "." fracmsg)))

        (when storagemsg (dotcat res "." storagemsg))

        (unless (or (equal id id2) (equal id bankid))
          ;; Update outboxhash
          (let ((outboxhash-item (bankmsg server $ATOUTBOXHASH outboxhash-msg)))
            (dotcat res "." outboxhash-item)
            (db-put db (outbox-hash-key id) outboxhash-item))

          ;; Append spend to outbox
          (setf (db-get db (outbox-dir id) time) outbox-item))

        (unless (equal id bankid)
          ;; Update balancehash
          (let ((balancehash-item (bankmsg server $ATBALANCEHASH balancehash-msg)))
            (dotcat res "." balancehash-item)
            (db-put db (balance-hash-key id) balancehash-item)))

        ;; Append spend to recipient's inbox
        (when newtime
          (setf (db-get db (inbox-key id2) newtime) inbox-item))

        ;; Force the user to do another getinbox, if anything appears
        ;; in his inbox since he last processed it.
        (db-put db (acct-last-key id) "-1")

        (values res assetid issuer storagefee digits)))))))

(defmethod post-storage-fee ((server server) assetid issuer storage-fee digits)
  ;; Credit storage fee to an asset issuer
  (let ((db (db server))
        (parser (parser server))
        (bankid (bankid server)))
    (with-db-lock (db (acct-time-key issuer))
      (let* ((key (storage-fee-key issuer assetid))
             (storage-msg (db-get db key)))
        (when storage-msg
          (let ((reqs (parse parser storage-msg)))
            (unless (eql 1 (length reqs))
              (error "Bad storagefee msg: ~s" storage-msg))
            (let* ((args (match-pattern parser (car reqs)))
                   (amount (getarg $AMOUNT args)))
              (unless (and (equal (getarg $CUSTOMER args) bankid)
                           (equal (getarg $REQUEST args) $STORAGEFEE)
                           (equal (getarg $BANKID args) bankid)
                           (equal (getarg $ASSET args) assetid))
                (error "Storage fee message malformed"))
              (setq storage-fee (bcadd storage-fee amount digits)))))
        (let* ((time (gettime server))
               (storage-msg (bankmsg server $STORAGEFEE
                                     bankid time assetid storage-fee)))
          (db-put db key storage-msg))))))

(define-message-handler do-spendreject $SPENDREJECT (server args reqs)
  "Process a spend|reject"
  (let ((db (db server))
        (parser (parser server))
        (id (getarg $CUSTOMER args))
        (msg (get-parsemsg (car reqs))))
    (with-verify-sigs-p (parser nil)
      (with-db-lock (db (acct-time-key id))
        (let* ((bankid (bankid server))
               (time (getarg $TIME args))
               (key (outbox-key id))
               (item (db-get db key time)))
          (unless item
            (error "No outbox entry for time: ~s" time))
          (let ((args (unpack-bankmsg server item $ATSPEND $SPEND)))
            (unless (equal time (getarg $TIME args))
              (error "Time mismatch in outbox item"))
            (when (equal (getarg $ID args) $COUPON)
              (error "Coupons must be redeemed, not cancelled"))
            (let* ((recipient (getarg $ID args))
                   (key (inbox-key recipient))
                   (inbox (db-contents db key))
                   (feeamt nil)
                   (feeasset nil))
              (dolist (intime inbox
                       (error "Spend has already been processed"))
                (let* ((item (or (db-get db key intime)
                                 (error "Spend has already been processed")))
                       (item2 nil)
                       (args (unpack-bankmsg server item $INBOX $SPEND)))
                  (when (equal (getarg $TIME args) time)
                    ;; Calculate the fee, if there is one
                    (let* ((reqs (getarg $UNPACK-REQS-KEY args))
                           (req (second reqs)))
                      (when req
                        (let ((args (match-pattern parser req)))
                          (unless (equal (getarg $CUSTOMER args) bankid)
                            (error "Fee message not from bank"))
                          (when (equal (getarg $REQUEST args) $ATTRANFEE)
                            (setq req (getarg $MSG args)
                                  args (match-pattern parser req))
                            (unless (equal (getarg $REQUEST args) $TRANFEE)
                              (error "Fee wrapper doesn't wrap fee message"))
                            (setq feeasset (getarg $ASSET args)
                                  feeamt (getarg $AMOUNT args))))))
                    ;; Found the inbox item corresponding to the outbox item.
                    ;; Make sure it's still there.
                    (with-db-lock (db (strcat key "/" intime))
                      (setq item2 (db-get db key intime)))
                    (unless item2
                      (error "Spend has already been processed"))
                    (when feeamt
                      (add-to-bank-balance server feeasset feeamt))
                    (let* ((newtime (gettime server))
                           (item (bankmsg server $INBOX newtime msg))
                           (key (inbox-key id)))
                      (setf (db-get db key newtime) item)
                      (return item))))))))))))

(define-message-handler do-couponenvelope $COUPONENVELOPE (server args reqs)
  "Redeem coupon by moving it from coupon/<coupon> to the customer inbox.
   This isn't the right way to do this.
   It really wants to be like processinbox, with new balances.
   You have to do it this way for a new registration, though."
  (let ((db (db server))
        (id (getarg $CUSTOMER args)))
    (with-db-lock (db (acct-time-key id))
      (do-couponenvelope-raw server args id)
      (bankmsg server $ATCOUPONENVELOPE (get-parsemsg (car reqs))))))

(defun do-couponenvelope-raw (server args id)
  "Called by do_register to process coupons there.
   Returns an error string or false."
  (check-type server server)

  (let ((db (db server))
        (bankid (bankid server))
        (parser (parser server))
        (encrypted-to (getarg $ID args)))
    (unless (equal encrypted-to bankid)
      (error "Coupon not encrypted to bank"))

    (let* ((coupon (privkey-decrypt (getarg $ENCRYPTEDCOUPON args) (privkey server)))
           (coupon-number (and (coupon-number-p coupon) coupon)))

      (unless coupon-number
        (let ((args (unpack-bankmsg server coupon $COUPON)))
          (unless (equal bankid (getarg $CUSTOMER args))
            (error "Coupon not signed by bank"))
          (setq coupon-number (getarg $COUPON args))))

      (let* ((coupon-number-hash (sha1 coupon-number))
             (key (strcat $COUPON "/" coupon-number-hash))
             (outbox-item nil))
        (with-db-lock (db key)
          (setq outbox-item (db-get db key))
          (when outbox-item (db-put db key nil)))

    (cond ((not outbox-item)
           (let* ((key (inbox-key id))
                  (inbox (db-contents db key)))
             (or (dolist (time inbox nil)
                   (let ((item (db-get db key time)))
                     (when (search #.(strcat "," $COUPON ",") item)
                       (let ((reqs (parse parser item)))
                         (when (> (length reqs) 1)
                           (let* ((req (second reqs))
                                  (msg (match-pattern parser req)))
                             (when (equal coupon-number-hash (getarg COUPON msg))
                               ;; Customer already redeemded this coupon.
                               ;; Success if he tries to do it again.
                               (return t))))))))
                 (error "Coupon already redeemed"))))
          (t
           (let* ((ok nil)
                  (args (unwind-protect
                             (prog1 (unpack-bankmsg server outbox-item $ATSPEND)
                                    (setq ok t))
                          (unless ok
                            ;; Make sure the spender can cancel the coupon
                            (db-put db key outbox-item))))
                  (reqs (getarg $UNPACK-REQS-KEY args))
                  (spendreq (getarg $MSG args))
                  (spendmsg (get-parsemsg spendreq))
                  (feemsg nil)
                  (feereq nil)
                  (newtime (gettime server))
                  (inbox-item (bankmsg server $INBOX newtime spendmsg))
                  (cnhmsg (bankmsg server $COUPONNUMBERHASH coupon-number-hash)))
             (dotcat inbox-item "." cnhmsg)
             (when (> (length reqs) 1)
               (setq feereq (second reqs)
                     feemsg (get-parsemsg feereq))
               (dotcat inbox-item "." feemsg))
             (let ((key (strcat (inbox-key id) "/" newtime)))
               (db-put db key inbox-item)))))))))

(define-message-handler do-getinbox $GETINBOX (server args reqs)
  "Query inbox"
  (let ((db (db server))
        (id (getarg $CUSTOMER args))
        (parser (parser server)))
    (with-db-lock (db (acct-time-key id))
      (checkreq server args)
      (let* ((inbox (scan-inbox server id))
             (res (bankmsg server $ATGETINBOX (get-parsemsg (car reqs))))
             (last "1"))

        (dolist (inmsg inbox)
          (dotcat res "." inmsg)
          (let ((args (match-message parser inmsg)))
            (when (equal (getarg $REQUEST args) $INBOX)
              (let ((time (getarg $TIME args)))
                (when (> (bccomp time last) 0)
                  (setq last time))))
            (setq args (match-pattern parser (getarg $MSG args)))
            (let ((argsid (getarg $ID args)))
              (unless (or (equal argsid id) (equal argsid $COUPON))
                (error "Inbox entry for wrong ID: ~s" id)))))

        (let* ((key (storage-fee-key id))
               (asset-ids (db-contents db key)))
          (dolist (assetid asset-ids)
            (dotcat res "." (db-get db key assetid))))

    ;; Update last time
    (db-put db (acct-last-key id) last)

    res))))

(define-message-handler do-processinbox $PROCESSINBOX (server args reqs)
  (let ((db (db server))
        (parser (parser server))
        (id (getarg $CUSTOMER args))
        res charges)

    (with-verify-sigs-p (parser nil)
      (with-db-lock (db (acct-time-key id))
        (multiple-value-setq (res charges)
          (do-processinbox-internal server args reqs))))
    (loop
       for assetid being the hash-key using (hash-value assetinfo) of charges
       for issuer = (storage-info-issuer assetinfo)
       for storage-fee = (storage-info-fee assetinfo)
       for digits = (storage-info-digits assetinfo)
       do
         (post-storage-fee server assetid issuer storage-fee digits))

    res))

(defun checktime (was sb place)
  (unless (equal was sb)
    (error "Time mismatch in ~a, was: ~s, sb: ~s"
           place was sb)))

(defun do-processinbox-internal (server args reqs)
  (check-type server server)
  (let* ((db (db server))
         (bankid (bankid server))
         (parser (parser server))
         (id (getarg $CUSTOMER args))
         (time (getarg $TIME args))
         (timelist (getarg $TIMELIST args))
         (inboxtimes (explode #\| timelist))
         (spends (make-equal-hash))
         (fees (make-equal-hash))
         (accepts nil)
         (rejects nil)
         (storagemsgs (make-equal-hash))
         (fracmsgs (make-equal-hash))
         (inbox-key (inbox-key id))
         (acctbals (make-equal-hash))
         (bals (make-equal-hash))
         (tokens 0)
         (oldneg (make-equal-hash))
         (newneg (make-equal-hash))
         (charges (make-equal-hash))
         (tobecharged nil)
         (inboxmsgs nil)
         (res (bankmsg server $ATPROCESSINBOX (get-parsemsg (car reqs))))
         (outboxtimes nil)
         (outboxhashreq nil)
         (outboxhashmsg nil)
         (outboxhash nil)
         (outboxcnt nil)
         (balancehashreq nil)
         (balancehashmsg nil)
         (balancehash nil)
         (balancehashcnt nil)
         (fracamts (make-equal-hash))
         (storageamts (make-equal-hash))
         (storagefees (make-equal-hash))
         (fractions (make-equal-hash)))

    ;; Burn the transaction, even if balances don't match.
    (deq-time server id time)

    ;; Collect the inbox items being processed
    (dolist (inboxtime inboxtimes)
      (let* ((item (db-get db inbox-key inboxtime))
             (itemargs (unpack-bankmsg server item $INBOX t))
             (request (getarg $REQUEST itemargs)))
        (unless (or (equal (getarg $ID itemargs) id)
                    (equal (getarg $ID itemargs) $COUPON))
          (error "Inbox corrupt. Item found for other customer"))
        (cond ((equal request $SPEND)
               (let* ((itemtime (getarg $TIME itemargs))
                      (itemreqs (getarg $UNPACK-REQS-KEY itemargs))
                      (itemcnt (length itemreqs))
                      (feereq (and (> itemcnt 1) (car (last itemreqs)))))
                 (setf (gethash itemtime spends) itemargs)
                 (when feereq
                   (let ((feeargs (match-pattern parser feereq)))
                     (when (equal (getarg $REQUEST feeargs) $ATTRANFEE)
                       (setq feeargs (match-pattern parser (getarg $MSG feeargs))))
                     (unless (equal (getarg $REQUEST feeargs) $TRANFEE)
                       (error "Inbox corrupt. Fee not properly encoded"))
                     (setf (gethash itemtime fees) feeargs)))))
              ((equal request $SPENDACCEPT)
               (push itemargs accepts))
              ((equal request $SPENDREJECT)
               (push itemargs rejects))
              (t (error "Inbox corrupted. Found '~a' item" request)))))

    (setq accepts (nreverse accepts)
          rejects (nreverse rejects))

    ;; Refund the transaction fees for accepted spends
    (dolist (itemargs accepts)
      (let* ((outboxtime (getarg $TIME itemargs))
             (spendfeeargs (get-outbox-args server id outboxtime))
             (feeargs (cdr spendfeeargs)))
        (push outboxtime outboxtimes)
        (when feeargs
          (let ((asset (getarg $ASSET feeargs))
                (amt (getarg $AMOUNT feeargs)))
            (setf (gethash asset bals) (bcadd (gethash asset bals 0) amt))))))

    ;; Credit the spend amounts for rejected spends, but do NOT
    ;; refund the transaction fees.
    (dolist (itemargs rejects)
      (let* ((outboxtime (getarg $TIME itemargs))
             (spendfeeargs (get-outbox-args server id outboxtime))
             (spendargs (car spendfeeargs))
             (asset (getarg $ASSET spendargs))
             (amt (getarg $AMOUNT spendargs))
             (spendtime (getarg $TIME spendargs)))
        (push outboxtime outboxtimes)
        (when (< (bccomp amt 0) 0)
          (setf (gethash asset oldneg) spendargs))
        (setf (gethash asset bals) (bcadd (gethash asset bals 0) amt))
        (push (list amt spendtime asset) tobecharged)))

    (let ((state (make-balance-state :acctbals acctbals
                                     :bals bals
                                     :tokens tokens
                                     :oldneg oldneg
                                     :newneg newneg
                                     :time time
                                     :charges charges)))

      ;; Go through the rest of the processinbox items, collecting
      ;; accept and reject instructions and balances.
      (dolist (req (cdr reqs))
        (let* ((reqmsg (get-parsemsg req))
               (args (match-pattern parser req))
               (request (getarg $REQUEST args))
               (argstime (getarg $TIME args)))
          (unless (equal (getarg $CUSTOMER args) id)
            (error "Item not from same customer as ~s" $PROCESSINBOX))
          (cond ((or (equal request $SPENDACCEPT)
                     (equal request $SPENDREJECT))
                 ;; $SPENDACCEPT => array($BANKID,$TIME,$id,$NOTE=>1),
                 ;; $SPENDREJECT => array($BANKID,$TIME,$id,$NOTE=>1),
                 (let* ((otherid (getarg $ID args))
                        (itemargs (gethash argstime spends)))
                   (unless itemargs
                     (error "'~a' not matched in '~a' item, argstime: ~a"
                            request $PROCESSINBOX argstime))
                   (cond ((equal request $SPENDACCEPT)
                          ;; Accepting the payment. Credit it.
                          (let ((itemasset (getarg $ASSET itemargs))
                                (itemamt (getarg $AMOUNT itemargs))
                                (itemtime (getarg $TIME itemargs)))
                            (when (and (< (bccomp itemamt 0) 0)
                                       (not (equal (getarg $CUSTOMER itemargs)
                                                   bankid)))
                              (setf (gethash itemasset oldneg) itemargs))
                            (setf (gethash itemasset bals)
                                  (bcadd (gethash itemasset bals 0) itemamt))
                            (push (list itemamt itemtime itemasset) tobecharged))
                          (dotcat res "." (bankmsg server $ATSPENDACCEPT reqmsg)))
                         (t
                          ;; Rejecting the payment. Credit the fee.
                          (let ((feeargs (gethash argstime fees)))
                            (when feeargs
                              (let ((feeasset (getarg $ASSET feeargs))
                                    (feeamt (getarg $AMOUNT feeargs)))
                                (setf (gethash feeasset bals)
                                      (bcadd (gethash feeasset bals 0) feeamt)))))
                          (dotcat res "." (bankmsg server $ATSPENDREJECT reqmsg))))
                   (let (inboxtime inboxmsg)
                     (cond ((equal otherid bankid)
                            (when (and (equal request $SPENDREJECT)
                                       (< (bccomp (getarg $AMOUNT itemargs) 0) 0))
                              (error "You may not reject a bank charge"))
                            (setq inboxtime request
                                  inboxmsg itemargs))
                           (t 
                            (setq inboxtime (gettime server)
                                  inboxmsg (bankmsg server $INBOX
                                                    inboxtime reqmsg))))
                     (push (list otherid inboxtime inboxmsg) inboxmsgs))))
                ((equal request $STORAGEFEE)
                 (checktime argstime time "storagefee item")
                 (let ((storageasset (getarg $ASSET args))
                       (storageamt (getarg $AMOUNT args)))
                   (when (gethash storageasset storagemsgs)
                     (error "Duplicate storage fee for asset: ~s" storageasset))
                   (setf (gethash storageasset storageamts) storageamt
                         (gethash storageasset storagemsgs)
                         (bankmsg server $ATSTORAGEFEE reqmsg))))
                ((equal request $FRACTION)
                 (checktime argstime time "fraction item")
                 (let ((fracasset (getarg $ASSET args))
                       (fracamt (getarg $AMOUNT args)))
                   (when (gethash fracasset fracmsgs)
                     (error "Duplicate fraction balance for asset: ~s" fracasset))
                   (setf (gethash fracasset fracamts) fracamt
                         (gethash fracasset fracmsgs)
                         (bankmsg server $ATFRACTION reqmsg))))
                ((equal request $OUTBOXHASH)
                 (when outboxhashreq
                   (error "~s appeared multiple times" $OUTBOXHASH))
                 (checktime argstime time "outboxhash")
                 (setq outboxhashreq req
                       outboxhashmsg (get-parsemsg req)
                       outboxhash (getarg $HASH args)
                       outboxcnt (getarg $COUNT args)))
                ((equal request $BALANCE)
                 (checktime argstime time "balance item")
                 (handle-balance-msg server id reqmsg args state))
                ((equal request $BALANCEHASH)
                 (when balancehashreq
                   (error "~s appeared multiple times" $BALANCEHASH))
                 (checktime argstime time "balancehash")
                 (setq balancehashreq req
                       balancehashmsg (get-parsemsg req)
                       balancehash (getarg $HASH args)
                       balancehashcnt (getarg $COUNT args)))
                (t
                 (error "~s not valid for ~s, only ~s, ~s, ~s, ~s, ~s, ~s, & ~s"
                        request $PROCESSINBOX
                        $SPENDACCEPT $SPENDREJECT
                        $STORAGEFEE $FRACTION $OUTBOXHASH
                        $BALANCE $BALANCEHASH)))))

      (setq tokens (balance-state-tokens state)))

    ;; Check that we have exactly as many negative balances after the transaction
    ;; as we had before.
    (unless (eql (hash-table-count oldneg) (hash-table-count newneg))
      (error "Negative balance count not conserved"))
    (loop
       for asset being the hash-keys of oldneg
       do
       (unless (gethash asset newneg)
         (error "Negative balance assets not conserved")))

    ;; Charge the new balance file tokens
    (let ((tokenid (tokenid server)))
      (setf (gethash tokenid bals) (bcsub (gethash tokenid bals 0) tokens)))

    ;; Work the storage fees into the balances
    (unless (eql 0 (hash-table-count charges))
      ;; Add storage fees for accepted spends and affirmed rejects
      (loop
         for (itemamt itemtime itemasset) in tobecharged
         for assetinfo = (gethash itemasset charges)
         when assetinfo
         do
         (let ((percent (storage-info-percent assetinfo)))
           (when (and percent (not (eql 0 (bccomp percent 0))))
             (let* ((digits (storage-info-digits assetinfo))
                    (itemfee (storage-fee itemamt itemtime time percent digits))
                    (storagefee (bcadd (storage-info-fee assetinfo)
                                       itemfee digits)))
               (setf (storage-info-fee assetinfo) storagefee)))))

      (loop
         for itemasset being the hash-key using (hash-value assetinfo) of charges
         for percent = (storage-info-percent assetinfo)
         when (and percent (not (eql 0 (bccomp percent 0))))
         do
           (let* ((digits (storage-info-digits assetinfo))
                  (storagefee (storage-info-fee assetinfo))
                  (bal (bcsub (gethash itemasset bals 0) storagefee digits))
                  (fraction (bcadd (gethash itemasset fractions 0)
                                   (storage-info-fraction assetinfo)
                                   digits)))
             (multiple-value-setq (bal fraction)
               (normalize-balance bal fraction digits))
             (setf (gethash itemasset bals) bal
                   (storage-info-fraction assetinfo) fraction
                   (gethash itemasset storagefees) storagefee
                   (gethash itemasset fractions) fraction))))

    (loop
       for storageasset being the hash-key using (hash-value storageamt)
       of storageamts
       for storagefee = (gethash storageasset storagefees)
       do
         (unless (eql 0 (bccomp storageamt storagefee))
           (error "Storage fee mismatch, sb: ~s, was: ~s" storageamt storagefee))
         (remhash storageasset storagefees))
    (unless (eql 0 (hash-table-count storagefees))
      (error "Storage fees missing for some assets"))

    (loop
       for fracasset being the hash-key using (hash-value fracamt) of fracamts
       for fraction = (gethash fracasset fractions)
       do
       (unless (eql 0 (bccomp fracamt fraction))
         (error "Fraction mismatch, sb: ~s, was: ~s" fracamt fraction))
       (remhash fracasset fractions))
    (unless (eql 0 (hash-table-count fractions))
      (error "Fraction balances missing for some assets"))

    ;; Check that the balances in the spend message, match the current balance,
    ;; minus amount spent minus fees.
    (let ((errmsg nil))
      (loop
         for balasset being the hash-key using (hash-value balamount) of bals
         do
           (unless (eql 0 (bccomp balamount 0))
             (let ((name (lookup-asset-name server balasset)))
               (if errmsg (dotcat errmsg ", ") (setq errmsg ""))
               (dotcat errmsg name ": " balamount))))
      (when errmsg
        (error "Balance discrepancies: ~s" errmsg)))

    ;; No outbox hash maintained for the bank
    (unless (equal id bankid)
      ;; Make sure the outbox hash was included iff needed
      (when (or (and outboxtimes (not outboxhashreq))
                (and (null outboxtimes) outboxhashreq))
        (error (if outboxhashreq
                   "~s included when not needed"
                   "~s missing")
               $OUTBOXHASH))

      (when outboxhashreq
        (multiple-value-bind (hash hashcnt)
            (outbox-hash server id nil outboxtimes)
          (unless (and (equal outboxhash hash)
                       (eql 0 (bccomp outboxcnt hashcnt)))
            (error "~s mismatch" $OUTBOXHASH))))

      ;; Check balancehash
      (unless balancehashreq
        (error "~s missing" $BALANCEHASH))

        (multiple-value-bind (hash hashcnt)
            (balancehash db (unpacker server) (balance-key id) acctbals)
          (unless (and (equal balancehash hash)
                       (eql 0 (bccomp balancehashcnt hashcnt)))
            (error "~s mismatch" $BALANCEHASH))))

    ;; All's well with the world. Commit this puppy.
    ;; Update balances.
    (let ((balancekey (balance-key id)))
      (loop
         for acct being the hash-key using (hash-value balances) of acctbals
         for acctkey = (strcat balancekey "/" acct)
         do
           (loop
              for balasset being the hash-key using (hash-value balance)
              of balances
              for balmsg = (bankmsg server $ATBALANCE balance)
              do
                (dotcat res "." balmsg)
                (setf (db-get db acctkey balasset) balmsg))))

    ;; Update accepted and rejected spenders' inboxes
    (dolist (inboxmsg (reverse inboxmsgs))
      (destructuring-bind (otherid inboxtime inboxmsg) inboxmsg
        (cond ((equal otherid bankid)
               (let ((request inboxtime)
                     (itemargs inboxmsg))
                 (when (equal request $SPENDREJECT)
                   ;; Return the funds to the bank's account
                   (add-to-bank-balance
                    server (getarg $ASSET itemargs) (getarg $AMOUNT itemargs)))))
              (t
               (let ((inboxkey (inbox-key otherid)))
                 (setf (db-get db inboxkey inboxtime) inboxmsg))))))

    ;; Remove no longer needed inbox and outbox entries.
    ;; Probably should have a bank config parameter to archive these somewhere.
    (let ((inboxkey (inbox-key id)))
      (dolist (inboxtime inboxtimes)
        (setf (db-get db inboxkey inboxtime) "")))

    ;; Clear processed outbox entries
    (let ((outboxkey (outbox-key id)))
      (dolist (outboxtime outboxtimes)
        (setf (db-get db outboxkey outboxtime) "")))

    (unless (equal id bankid)
      ;; Update outboxhash
      (when outboxhashreq
        (let ((outboxhash-item (bankmsg server $ATOUTBOXHASH outboxhashmsg)))
          (dotcat res "." outboxhash-item)
          (db-put db (outbox-hash-key id) outboxhash-item)))

      ;; Update balancehash
      (let ((balancehash-item (bankmsg server $ATBALANCEHASH balancehashmsg)))
        (dotcat res "." balancehash-item)
        (db-put db (balance-hash-key id) balancehash-item)))

    ;; Update fractions, and add fraction and storagefee messages to result
    (loop
       for storagemsg being the hash-values of storagemsgs
       do
         (dotcat res "." storagemsg))
    (loop
       for fracasset being the hash-key using (hash-value fracmsg) of fracmsgs
       for key = (fraction-balance-key id fracasset)
       do  
         (dotcat res "." fracmsg)
         (db-put db key fracmsg))
    
    (values res charges)))

(defun get-outbox-args (server id spendtime)
  (check-type server server)

  (let* ((db (db server))
         (parser (parser server))
         (bankid (bankid server))
         (outboxkey (outbox-key id))
         (spendmsg (or (db-get db outboxkey spendtime)
                       (error "Can't find outbox item: ~s" spendtime)))
         (reqs (parse parser spendmsg))
         (spendargs (match-pattern parser (car reqs)))
         (feeargs (and (> (length reqs) 1)
                       (match-pattern parser (second reqs)))))
    (unless (and (equal (getarg $CUSTOMER spendargs) bankid)
                 (equal (getarg $REQUEST spendargs) $ATSPEND)
                 (or (null feeargs)
                     (and (equal (getarg $CUSTOMER feeargs) bankid)
                          (equal (getarg $REQUEST feeargs) $ATTRANFEE))))
      (error "Outbox corrupted"))

    (setq spendargs (match-pattern parser (getarg $MSG spendargs)))
    (when feeargs
      (setq feeargs (match-pattern parser (getarg $MSG feeargs))))
    (unless (and (equal (getarg $CUSTOMER spendargs) id)
                 (equal (getarg $REQUEST spendargs) $SPEND)
                 (or (null feeargs)
                     (and (equal (getarg $CUSTOMER feeargs) id)
                          (equal (getarg $REQUEST feeargs) $TRANFEE))))
      (error "Outbox inner messages corrupted"))
    (cons spendargs feeargs)))

(define-message-handler do-storagefees $STORAGEFEES (server args reqs)
  ;; Process a storagefees request
  (let ((db (db server))
        (bankid (bankid server))
        (id (getarg $CUSTOMER args)))
    (with-db-lock (db (acct-time-key id))
      (checkreq server args)
      (let* ((inboxkey (inbox-key id))
             (key (storage-fee-key id))
             (assetids (db-contents db key)))
        (dolist (assetid assetids)
          (let* ((storagefee (db-get db key assetid))
                 (args (unpack-bankmsg server storagefee $STORAGEFEE))
                 (amount (getarg $AMOUNT args)))
            (unless (equal assetid (getarg $ASSET args))
              (error "Asset mismatch, sb: ~s, was: ~s"
                     assetid (getarg $ASSET args)))
            (multiple-value-bind (percent fraction)
                (storage-info server id assetid)
              (let ((digits (fraction-digits percent)))
                (multiple-value-setq (amount fraction)
                  (normalize-balance amount fraction digits)))
              (when (> (bccomp amount 0) 0)
                (let* ((time (gettime server))
                       (storagefee (bankmsg server $STORAGEFEE
                                            bankid time assetid fraction))
                       (spend (bankmsg server $SPEND
                                       bankid time id assetid amount
                                       "Storage fees"))
                       (inbox (bankmsg server $INBOX time spend)))
                  (setf (db-get db key assetid) storagefee)
                  (setf (db-get db inboxkey time) inbox)))))))
      (bankmsg server $ATSTORAGEFEES (get-parsemsg (car reqs))))))

(define-message-handler do-getasset $GETASSET (server args reqs)
  (declare (ignore reqs))
  (let ((db (db server))
        (id (getarg $CUSTOMER args)))
    (with-db-lock (db (acct-time-key id))
      (checkreq server args)
      (let ((assetid (getarg $ASSET args)))
        (unless (and assetid (> (length assetid) 0))
          (error "Illegal assetid: ~s" assetid))
        (or (db-get db $ASSET assetid)
            (error "Unknown asset: ~s" assetid))))))

(define-message-handler do-asset $ASSET (server args reqs)
  (let ((db (db server))
        (id (getarg $CUSTOMER args))
        (bankid (bankid server))
        (parser (parser server)))
    (with-db-lock (db (acct-time-key id))

      (when (< (length reqs) 2)
        (error "No balance items"))

      ;; $ASSET => array($BANKID,$ASSET,$SCALE,$PRECISION,$ASSETNAME),
      (let* ((assetid (getarg $ASSET args))
             (scale (getarg $SCALE args))
             (precision (getarg $PRECISION args))
             (assetname (getarg $ASSETNAME args))
             (storage-msg nil)
             (exists-p (is-asset-p server assetid))
             (tokens (if (equal id bankid) "0" "1"))
             (bals (make-equal-hash))
             (acctbals (make-equal-hash))
             (oldneg (make-equal-hash))
             (newneg (make-equal-hash))
             (tokenid (tokenid server))
             (time nil)
             (state (make-balance-state
                     :acctbals acctbals
                     :bals bals
                     :tokens tokens
                     :oldneg oldneg
                     :newneg newneg
                     ;; 'time' initialized below
                     ))
             (balancehashreq nil)
             (balancehash nil)
             (balancehashcnt nil)
             (balancehashmsg nil)
             )

        (unless (and (is-numeric-p scale t) (is-numeric-p precision t)
                     (> (bccomp scale 0) 0) (> (bccomp precision 0) 0))
          (error "Scale & precision must be integers >= 0"))

        (when (> (bccomp scale 10) 0)
          (error "Maximum scale is 10"))

        ;; Don't really need this restriction. Maybe widen it a bit?
        (unless (every #'is-alphanumeric-or-space-p assetname)
          (error "Asset name must contain only letters and digits"))

        (unless (equal assetid (assetid id scale precision assetname))
          (error "Asset id is not sha1 hash of 'id,scale,precision,name'"))

        (unless exists-p (setf (gethash assetid bals) "-1"))
        (setf (gethash tokenid bals) "0")

        (dolist (req (cdr reqs))
          (let* ((reqargs (match-pattern parser req))
                 (reqid (getarg $CUSTOMER reqargs))
                 (request (getarg $REQUEST reqargs))
                 (reqtime (getarg $TIME reqargs))
                 (reqmsg (get-parsemsg req)))
            (unless time
              ;; Burn the transaction
              (setq time reqtime)
              (deq-time server id time)
              (setf (balance-state-time state) time))
            (unless (equal reqid id) (error "ID mismatch"))
            (cond ((equal request $STORAGE)
                   (when storage-msg (error "Duplicate storage fee"))
                   (setq storage-msg reqmsg))
                  ((equal request $BALANCE)
                   (handle-balance-msg server id reqmsg reqargs state assetid))
                  ((equal request $BALANCEHASH)
                   (when balancehashreq
                     (error "~s appeared multiple times" $BALANCEHASH))
                   (setq balancehashreq req
                         balancehash (getarg $HASH reqargs)
                         balancehashcnt (getarg $COUNT reqargs)
                         balancehashmsg reqmsg))
                  (t (error "~s not valid for asset creation. Only ~s, ~s, & ~s"
                            request $STORAGE $BALANCE $BALANCEHASH)))))

        ;; Check that we have exactly as many negative balances after the transaction
        ;; as we had before, plus one for the new asset.
        (unless exists-p (setf (gethash assetid oldneg) $MAIN))
        (unless (equal (hash-table-count oldneg) (hash-table-count newneg))
          (error "Negative balance count not conserved"))
        (loop
           for asset being the hash-keys of oldneg
           do
           (unless (gethash asset newneg)
             (error "Negative balance assets not conserved")))

        ;; Charge the new file tokens
        (setq tokens (balance-state-tokens state))
        (setf (gethash tokenid bals) (bcsub (gethash tokenid bals 0) tokens))

        (let ((errmsg nil))
          ;; Check that the balances in the spend message, match the current balance,
          ;; minus amount spent minus fees.
          (loop
             for balasset being the hash-key using (hash-value balamount) of bals
             unless (eql 0 (bccomp balamount 0))
             do
             (let ((name (if (equal balasset assetid)
                             assetname
                             (lookup-asset-name server balasset))))
               (if errmsg (dotcat errmsg ", ") (setq errmsg ""))
               (dotcat errmsg name ": " balamount)))
          (when errmsg (error "Balance discrepancies: ~s" errmsg)))

        ;; balancehash must be included
        (unless balancehashreq (error "~s missing" $BALANCEHASH))

        (multiple-value-bind (hash hashcnt)
            (balancehash db (unpacker server) (balance-key id) acctbals)
          (unless (and (equal balancehash hash)
                       (eql 0 (bccomp balancehashcnt hashcnt)))
            (error "~s mismatch, hash: ~s, sb: ~s, count: ~s, sb: ~s"
                   $BALANCEHASH balancehash hash balancehashcnt hashcnt)))
  
        ;; All's well with the world. Commit this puppy.
        ;; Add asset
        (let ((res (bankmsg server $ATASSET (get-parsemsg (car reqs)))))
          (when storage-msg
            (dotcat res "." (bankmsg server $ATSTORAGE storage-msg)))

          (setf (db-get db $ASSET assetid) res)

          ;; Credit bank with tokens
          (add-to-bank-balance server tokenid tokens)

          ;; Update balances
          (let ((balancekey (balance-key id)))
            (loop
               for acct being the hash-key using (hash-value balances) of acctbals
               for acctkey = (strcat balancekey "/" acct)
               do
               (loop
                  for balasset being the hash-key using (hash-value balance)
                  of balances
                  for balmsg = (bankmsg server $ATBALANCE balance)
                  do
                  (dotcat res "." balmsg)
                  (setf (db-get db acctkey balasset) balmsg))))

          ;; Update balancehash
          (let ((balancehash-item (bankmsg server $ATBALANCEHASH balancehashmsg)))
            (dotcat res "." balancehash-item)
            (db-put db (balance-hash-key id) balancehash-item))

          res)))))

(define-message-handler do-getbalance $GETBALANCE (server args reqs)
  (declare (ignore reqs))
  (let ((db (db server))
        (id (getarg $CUSTOMER args))
        (acct (getarg $ACCT args))
        (assetid (getarg $ASSET args))
        (res "")
        assetnames
        assetkeys
        acctkeys
        assetids)

    (with-db-lock (db (acct-time-key id))
      (checkreq server args)

      (cond ((and acct (not (equal acct "")))
             (setq acctkeys (list (acct-balance-key id acct))))
            (t (let* ((balancekey (balance-key id))
                      (acctnames (db-contents db balancekey)))
                 (dolist (name acctnames)
                   (push (strcat balancekey "/" name) acctkeys))
                 (setf acctkeys (nreverse acctkeys)))))

      (dolist (acctkey acctkeys)
        (setq assetnames
              (if (and assetid (not (equal assetid "")))
                  (list assetid)
                  (db-contents db acctkey))
              assetkeys nil)
        (dolist (name assetnames)
          (push (strcat acctkey "/" name) assetkeys))
        (dolist (assetkey assetkeys)
          (let ((bal (db-get db assetkey)))
            (when bal
                (unless (equal res "") (dotcat res "."))
                (dotcat res bal)))))

      ;; Get the fractions
      (setq assetids
            (if assetid
                (list assetid)
                assetnames))
      (dolist (assetid assetids)
        (let* ((fractionkey (fraction-balance-key id assetid))
               (fraction (db-get db fractionkey)))
          (when fraction (dotcat res "." fraction))))

      (let ((balancehash (db-get db (balance-hash-key id))))
        (when balancehash
          (unless (equal res "") (dotcat res "."))
          (dotcat res balancehash))))

    res))

(define-message-handler do-getoutbox $GETOUTBOX (server args reqs)
  (let ((db (db server))
        (id (getarg $CUSTOMER args)))
    (with-db-lock (db (acct-time-key id))
      (checkreq server args)

      ;; $GETOUTBOX => array($BANKID,$REQ)
      (let* ((id (getarg $CUSTOMER args))
             (msg (bankmsg server $ATGETOUTBOX (get-parsemsg (car reqs))))
             (outboxkey (outbox-key id))
             (contents (db-contents db outboxkey))
             (outboxhash (db-get db (outbox-hash-key id))))

        (dolist (time contents)
          (dotcat msg "." (db-get db outboxkey time)))

        (when outboxhash (dotcat msg "." outboxhash))

        msg))))

;;;
;;; End request processing
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter *server-commands* nil)

(defun server-commands ()
  (or *server-commands*
      (let* ((patterns (patterns))
             (names `(,$BANKID
                      ,$ID
                      ,$REGISTER
                      ,$GETREQ
                      ,$GETTIME
                      ,$GETFEES
                      ,$SPEND
                      ,$SPENDREJECT
                      ,$COUPONENVELOPE
                      ,$GETINBOX
                      ,$PROCESSINBOX
                      ,$STORAGEFEES
                      ,$GETASSET
                      ,$ASSET
                      ,$GETOUTBOX
                      ,$GETBALANCE))
             (commands (make-hash-table :test #'equal)))
      (loop
         for name in names
         for pattern =  (gethash name patterns)
         do
           (setf (gethash name commands) pattern))
      (setq *server-commands* commands))))

(defun shorten (string maxlen)
  (if (> (length string) maxlen)
      (strcat (subseq string (- maxlen 3)) "...")
      string))

(defmethod process ((server server) msg)
  "Process a message and return the response.
   This is usually all you'll call from outside."
  (handler-case
      (process-internal server msg)
    (error (c)
      (failmsg server msg (format nil "~a" c)))))

(defun process-internal (server msg)
  (let* ((parser (parser server))
         (reqs (parse parser msg))
         (request (gethash 1 (car reqs)))
         (pattern (gethash request (server-commands))))
    (unless pattern
      (error "Unknown request: ~s" request))
    (setq pattern (append `(,$CUSTOMER ,$REQUEST) pattern))
    (let* ((args (or (match-args (car reqs) pattern)
                     (error "Can't match message")))
           (args-bankid (getarg $BANKID args))
           (note (getarg $NOTE args))
           (handler (get-message-handler request)))
      (unless (or (null args-bankid)
                  (and (equal "0" args-bankid)
                       (equal $BANKID (getarg $REQUEST args)))
                  (equal args-bankid (bankid server)))
        (error "bankid mismatch"))
      (when (> (length note) 4096)
        (error "Note too long. Max: 4096 chars"))
      (funcall handler server args reqs))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Copyright 2009 Bill St. Clair
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions
;;; and limitations under the License.
;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
