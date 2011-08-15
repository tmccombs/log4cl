
(in-package cl-log)

(defstruct (console-appender
	     (:include appender
		       (layout (make-default-layout)))))

(defmethod appender-do-append ((this console-appender)
			       (level integer)
			       (category string)
			       (log-func function))
  (with-lock-held ((appender-lock this))
    (append-to-stream *debug-io* this level category log-func)
    #+clisp (finish-output *debug-io*))
  (values))
