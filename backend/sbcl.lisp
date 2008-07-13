;;;; $Id$
;;;; $URL$

;;;; See LICENSE for licensing information.

(in-package :usocket)

;; There's no way to preload the sockets library other than by requiring it
;;
;; ECL sockets has been forked off sb-bsd-sockets and implements the
;; same interface. We use the same file for now.
#+ecl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sockets))

#+sbcl
(progn
  #-win32
  (defun get-host-name ()
    (sb-unix:unix-gethostname))

  ;; we assume winsock has already been loaded, after all,
  ;; we already loaded sb-bsd-sockets and sb-alien
  #+win32
  (defun get-host-name ()
    (sb-alien:with-alien ((buf (sb-alien:array sb-alien:char 256)))
       (let ((result (sb-alien:alien-funcall
                      (sb-alien:extern-alien "gethostname"
                                             (sb-alien:function sb-alien:int
                                                                (* sb-alien:char)
                                                                sb-alien:int))
                      (sb-alien:cast buf (* sb-alien:char))
                      256)))
         (when (= result 0)
           (sb-alien:cast buf sb-alien:c-string))))))


#+ecl
(progn
  #-:wsock
  (ffi:clines
   "#include <errno.h>"
   "#include <sys/socket.h>")
  #+:wsock
  (ffi:clines
   "#ifndef FD_SETSIZE"
   "#define FD_SETSIZE 1024"
   "#endif"
   "#include <winsock2.h>")

  (ffi:clines
   "#include <ecl/ecl-inl.h>")

  #+:prefixed-api
  (ffi:clines
   "#define CONS(x, y) ecl_cons((x), (y))"
   "#define MAKE_INTEGER(x) ecl_make_integer((x))")
  #-:prefixed-api
  (ffi:clines
   "#define CONS(x, y) make_cons((x), (y))"
   "#define MAKE_INTEGER(x) make_integer((x))")

  (defun fd-setsize ()
    (ffi:c-inline () () :fixnum
     "FD_SETSIZE" :one-liner t))

  (defun get-host-name ()
    (ffi:c-inline
     () () :object
     "{ char *buf = cl_alloc_atomic(257);

        if (gethostname(buf,256) == 0)
          @(return) = make_simple_base_string(buf);
        else
          @(return) = Cnil;
      }" :one-liner nil :side-effects nil))

  (defun read-select (read-fds to-secs &optional (to-musecs 0))
    (ffi:c-inline (read-fds to-secs to-musecs) (t t :unsigned-int) t
      "{
          fd_set rfds;
          cl_object cur_fd = #0;
          int count;
          int max_fd = -1;
          struct timeval tv;

          FD_ZERO(&rfds);
          while (CONSP(cur_fd)) {
            int fd = fixint(cur_fd->cons.car);
            max_fd = (max_fd > fd) ? max_fd : fd;
            FD_SET(fd, &rfds);
            cur_fd = cur_fd->cons.cdr;
          }

          if (#1 != Cnil) {
            tv.tv_sec = fixnnint(#1);
            tv.tv_usec = #2;
          }
          count = select(max_fd + 1, &rfds, NULL, NULL,
                         (#1 != Cnil) ? &tv : NULL);

          if (count == 0)
            @(return 0) = Cnil;
            @(return 1) = Cnil;
          else if (count < 0)
            /*###FIXME: We should be raising an error here...

              except, ofcourse in case of EINTR or EAGAIN */

            @(return 0) = Cnil;
            @(return 1) = MAKE_INTEGER(errno);
          else
            {
              cl_object rv = Cnil;
              cur_fd = #0;

              /* when we're going to use the same code on Windows,
                 as well as unix, we can't be sure it'll fit into
                 a fixnum: these aren't unix filehandle bitmaps sets on
                 Windows... */

              while (CONSP(cur_fd)) {
                int fd = fixint(cur_fd->cons.car);
                if (FD_ISSET(fd, &rfds))
                  rv = CONS(MAKE_INTEGER(fd), rv);

                cur_fd = cur_fd->cons.cdr;
              }
              @(return 0) = rv;
              @(return 1) = Cnil;
            }
}"))

)

(defun map-socket-error (sock-err)
  (map-errno-error (sb-bsd-sockets::socket-error-errno sock-err)))

(defparameter +sbcl-condition-map+
  '((interrupted-error . interrupted-condition)))

(defparameter +sbcl-error-map+
  `((sb-bsd-sockets:address-in-use-error . address-in-use-error)
    (sb-bsd-sockets::no-address-error . address-not-available-error)
    (sb-bsd-sockets:bad-file-descriptor-error . bad-file-descriptor-error)
    (sb-bsd-sockets:connection-refused-error . connection-refused-error)
    (sb-bsd-sockets:invalid-argument-error . invalid-argument-error)
    (sb-bsd-sockets:no-buffers-error . no-buffers-error)
    (sb-bsd-sockets:operation-not-supported-error
     . operation-not-supported-error)
    (sb-bsd-sockets:operation-not-permitted-error
     . operation-not-permitted-error)
    (sb-bsd-sockets:protocol-not-supported-error
     . protocol-not-supported-error)
    (sb-bsd-sockets:unknown-protocol
     . protocol-not-supported-error)
    (sb-bsd-sockets:socket-type-not-supported-error
     . socket-type-not-supported-error)
    (sb-bsd-sockets:network-unreachable-error . network-unreachable-error)
    (sb-bsd-sockets:operation-timeout-error . timeout-error)
    (sb-bsd-sockets:socket-error . ,#'map-socket-error)

    ;; Nameservice errors: mapped to unknown-error
    (sb-bsd-sockets:no-recovery-error . ns-no-recovery-error)
    (sb-bsd-sockets:try-again-error . ns-try-again-condition)
    (sb-bsd-sockets:host-not-found-error . ns-host-not-found-error)))

(defun handle-condition (condition &optional (socket nil))
  "Dispatch correct usocket condition."
  (typecase condition
    (error (let* ((usock-error (cdr (assoc (type-of condition)
                                           +sbcl-error-map+)))
                  (usock-error (if (functionp usock-error)
                                   (funcall usock-error condition)
                                 usock-error)))
             (when usock-error
                 (error usock-error :socket socket))))
    (condition (let* ((usock-cond (cdr (assoc (type-of condition)
                                              +sbcl-condition-map+)))
                      (usock-cond (if (functionp usock-cond)
                                      (funcall usock-cond condition)
                                    usock-cond)))
                 (if usock-cond
                     (signal usock-cond :socket socket))))))


(defun socket-connect (host port &key (element-type 'character) timeout deadline)
  (declare (ignore deadline))
  (when timeout
    (warn "SOCKET-CONNECT timeout not supported in SBCL"))
  (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket
                                :type :stream :protocol :tcp))
         (stream (sb-bsd-sockets:socket-make-stream socket
                                                    :input t
                                                    :output t
                                                    :buffering :full
                                                    :element-type element-type))
         ;;###FIXME: The above line probably needs an :external-format
         (usocket (make-stream-socket :stream stream :socket socket))
         (ip (host-to-vector-quad host)))
    (with-mapped-conditions (usocket)
      (sb-bsd-sockets:socket-connect socket ip port))
    usocket))

(defun socket-listen (host port
                           &key reuseaddress
                           (reuse-address nil reuse-address-supplied-p)
                           (backlog 5)
                           (element-type 'character))
  (let* ((reuseaddress (if reuse-address-supplied-p reuse-address reuseaddress))
         (ip (host-to-vector-quad host))
         (sock (make-instance 'sb-bsd-sockets:inet-socket
                              :type :stream :protocol :tcp)))
    (with-mapped-conditions ()
       (setf (sb-bsd-sockets:sockopt-reuse-address sock) reuseaddress)
       (sb-bsd-sockets:socket-bind sock ip port)
       (sb-bsd-sockets:socket-listen sock backlog)
       (make-stream-server-socket sock :element-type element-type))))

(defmethod socket-accept ((socket stream-server-usocket) &key element-type)
  (with-mapped-conditions (socket)
     (let ((sock (sb-bsd-sockets:socket-accept (socket socket))))
       (make-stream-socket
        :socket sock
        :stream (sb-bsd-sockets:socket-make-stream
                 sock
                 :input t :output t :buffering :full
                 :element-type (or element-type
                                   (element-type socket)))))))

;; Sockets and their associated streams are modelled as
;; different objects. Be sure to close the stream (which
;; closes the socket too) when closing a stream-socket.
(defmethod socket-close ((usocket usocket))
  (with-mapped-conditions (usocket)
    (sb-bsd-sockets:socket-close (socket usocket))))

(defmethod socket-close ((usocket stream-usocket))
  (with-mapped-conditions (usocket)
    (close (socket-stream usocket))))

(defmethod get-local-name ((usocket usocket))
  (sb-bsd-sockets:socket-name (socket usocket)))

(defmethod get-peer-name ((usocket stream-usocket))
  (sb-bsd-sockets:socket-peername (socket usocket)))

(defmethod get-local-address ((usocket usocket))
  (nth-value 0 (get-local-name usocket)))

(defmethod get-peer-address ((usocket stream-usocket))
  (nth-value 0 (get-peer-name usocket)))

(defmethod get-local-port ((usocket usocket))
  (nth-value 1 (get-local-name usocket)))

(defmethod get-peer-port ((usocket stream-usocket))
  (nth-value 1 (get-peer-name usocket)))


(defun get-host-by-address (address)
  (with-mapped-conditions ()
    (sb-bsd-sockets::host-ent-name
        (sb-bsd-sockets:get-host-by-address address))))

(defun get-hosts-by-name (name)
  (with-mapped-conditions ()
     (sb-bsd-sockets::host-ent-addresses
         (sb-bsd-sockets:get-host-by-name name))))

#+sbcl
(progn
  #-win32
  (defun wait-for-input-internal (sockets &key timeout)
    (with-mapped-conditions ()
      (sb-alien:with-alien ((rfds (sb-alien:struct sb-unix:fd-set)))
         (sb-unix:fd-zero rfds)
         (dolist (socket sockets)
           (sb-unix:fd-set
            (sb-bsd-sockets:socket-file-descriptor (socket socket))
            rfds))
         (multiple-value-bind
             (secs musecs)
             (split-timeout (or timeout 1))
           (multiple-value-bind
               (count err)
               (sb-unix:unix-fast-select
                (1+ (reduce #'max (mapcar #'socket sockets)
                            :key #'sb-bsd-sockets:socket-file-descriptor))
                (sb-alien:addr rfds) nil nil
                (when timeout secs) musecs)
	     (if (null count)
		 (unless (= err sb-unix:EINTR)
		   (error (map-errno-error err)))
		 (when (< 0 count)
		   ;; process the result...
		   (remove-if
		    #'(lambda (x)
			(not (sb-unix:fd-isset
			      (sb-bsd-sockets:socket-file-descriptor (socket x))
			      rfds)))
		    sockets))))))))

  #+win32
  (warn "wait-for-input not (yet!) supported...")
  )

#+ecl
(progn
  (defun wait-for-input-internal (sockets &key timeout)
    (with-mapped-conditions ()
      (multiple-value-bind
          (secs usecs)
          (split-timeout (or timeout 1))
        (let* ((sock-fds (mapcar #'sb-bsd-sockets:socket-file-descriptor
                                 (mapcar #'socket sockets))))
	  (multiple-value-bind
		(result-fds err)
	      (read-select sock-fds (when timeout secs) usecs)
	    (if (null err)
		(remove-if #'(lambda (s)
			       (not
				(member
				 (sb-bsd-sockets:socket-file-descriptor
				  (socket s))
				 result-fds)))
			   sockets)
		(error (map-errno-error err))))))))
  )
