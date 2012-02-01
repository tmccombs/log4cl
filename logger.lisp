;;;
;;; Global variables, logger and logger-state structures, and utility functions
;;;
(in-package :log4cl)

#+sbcl (declaim (sb-ext:always-bound
                 *hierarchy* *log-indent*
                 *ndc-context* *log-event-time*
                 *hierarchy-lock*
                 *name-to-hierarchy*
                 *hierarchy-max*))

(declaim (special *root-logger*)
         (type logger *root-logger*)
	 (type fixnum  *hierarchy-max* *hierarchy* *log-indent*)
	 (type hash-table *name-to-hierarchy*)
         (inline is-enabled-for current-state hierarchy-index
                 log-level-to-string
                 log-event-time))

(defstruct logger-state
  "Structure containng logger internal state"
  ;; list of appenders attached to this logger
  (appenders nil :type list)
  ;; explicit log level for this logger if its set
  (level nil :type (or null fixnum))
  ;; If true then log level and appenders are inherited from
  ;; parent logger
  (additivity t :type boolean)
  ;; performance hack, for each log level we set a bit in mask, if a
  ;; log message with said level will reach any appenders either in
  ;; this logger or it's parents
  ;;
  ;; update-logger-mask function recalculates this value for parent
  ;; and child loggers
  (mask 0 :type fixnum))

(defstruct (logger (:constructor create-logger)
                   (:print-function 
                    (lambda  (logger stream depth)
                      (declare (ignore depth))
                      (let ((*print-circle* nil))
                        (print-unreadable-object (logger stream)
                          (princ "LOGGER " stream)
                          (princ (if (zerop (length (logger-category logger))) "+ROOT+"
                                     (logger-category logger)) stream))))))
  ;; Full category name as in parent.sub-parent.thislogger
  (category  nil :type string)
  ;; Logger's native category separator string
  (category-separator nil :type string)
  ;; position of the 1st character of this logger name in full
  ;; category name
  (name-start-pos 0 :type fixnum)
  ;; parent logger, only nil for the root logger
  (parent    nil :type (or null logger))
  ;; How many parents up and including the root logger this logger has
  (depth     0   :type fixnum)
  ;; child loggers
  (children  nil :type (or null hash-table))
  ;; per-hierarchy configuration
  (state (map-into (make-array *hierarchy-max*) #'make-logger-state)
   :type (simple-array logger-state *)))

(defun log-level-to-string (level)
  "Return log-level string for the level"
  (aref +log-level-to-string+ level))

(defun make-log-level (arg)
  "Translate a more human readable log level into one of the log
level constants, by calling LOG-LEVEL-FROM-OBJECT on ARG and current
value of *PACKAGE* "
  (log-level-from-object arg *package*))

(defun effective-log-level (logger)
  "Return logger's own log level (if set) or the one it
had inherited from parent"
  (declare (type (or null logger) logger))
  (if (null logger) +log-level-off+
      (let* ((state (current-state logger))
	     (level (logger-state-level state)))
	(or level
	    (effective-log-level (logger-parent logger))))))

(defun have-appenders-for-level (logger level)
  "Return non-NIL if logging with LEVEL will actually
reach any appenders"
  (declare (type logger logger) (type fixnum level))
  ;; Note: below code actually walk parent chain twice but since its
  ;; cached anyway, don't optimize unless becomes a problem
  (labels ((have-appenders (logger)
	     (when logger
	       (or (logger-state-appenders (current-state logger))
		   (have-appenders (logger-parent logger))))))
    (let* ((logger-level (effective-log-level logger)))
      (and (>= logger-level level)
	   (have-appenders logger)))))

(defun map-logger-children (function logger)
  "Apply the function to all of logger's children (but not their
descedants)"
  (let ((child-hash (logger-children logger)))
    (when child-hash
      (maphash (lambda (name logger)
                 (declare (ignore name))
                 (funcall function logger))
               child-hash))))

(defun adjust-logger (logger)
  "Recalculate LOGGER mask by finding out which log levels have
reachable appenders. "
  (labels ((doit (logger)
             (let ((state (current-state logger))
                   (mask 0))
               (declare (type fixnum mask))
               (loop
                  for level from +min-log-level+ upto +max-log-level+
                  if (have-appenders-for-level logger level)
                  do (setf mask (logior mask (ash 1 level))))
               (setf (logger-state-mask state) mask)
               (map-logger-children #'doit logger))))
    (doit logger))
  (values))

(defun get-logger (category)
  "Get the logger with a given category name. Logger is created
if it does not exist"
  (declare (type (or string null) category))
  (cond ((or (null category)
             (zerop (length category))) *root-logger*)
        (t (let* ((separator (naming-option *package* :category-separator))
                  (pos (search separator category :from-end t))
                  (parent (if (null pos) *root-logger*
                              (get-logger (subseq category 0 pos))))
                  (logger (let ((child-hash (logger-children parent)))
                            (when child-hash
                              (gethash category child-hash)))))
             (unless logger
               (setq logger (create-logger :category category
                                           :category-separator separator
                                           :parent parent
                                           :name-start-pos (if pos (1+ pos) 0)
                                           :depth (1+ (logger-depth parent))))
               (unless (logger-children parent)
                 (setf (logger-children parent)
                       (make-hash-table :test #'equal)))
               (setf (gethash category (logger-children parent)) logger)
               (dotimes (*hierarchy* *hierarchy-max*)
                 (adjust-logger logger)))
             logger))))

(defun current-state (logger)
  (svref (logger-state logger) *hierarchy*))

(defun is-enabled-for (logger level)
  "Returns t if log level is enabled for the logger in the
context of the current application."
  (declare (type logger logger) (type fixnum level))
  (let* ((state (current-state logger))
	 (mask (logger-state-mask state)))
    (declare (type fixnum mask))
    (not (zerop (logand (the fixnum (ash 1 level)) mask)))))

(defun expand-log-with-level (env level args)
  "Returns a FORM that is used as an expansion of log-nnnnn macros"
  (declare (type fixnum level)
	   (type list args))
  (multiple-value-bind (logger-form args)
      (resolve-logger-form *package* env args)
    (let* ((logger-symbol (gensym "logger"))
           (log-stmt (gensym "log-stmt")))
      (if args 
          `(let ((,logger-symbol ,logger-form))
             #+sbcl(declare (sb-ext:muffle-conditions sb-ext:compiler-note))
             (when
                 (locally (declare (optimize (safety 0) (debug 0) (speed 3)))
                   (is-enabled-for ,logger-symbol ,level))
               (flet ((,log-stmt (stream)
                        (declare (type stream stream))
                        (format stream ,@args)))
                 (declare (dynamic-extent #',log-stmt))
                 (locally (declare (optimize (safety 0) (debug 0) (speed 3)))
                   (log-with-logger ,logger-symbol ,level #',log-stmt))))
             (values))
          ;; null args means its being used for checking if level is enabled
          ;; in the (when (log-debug) ... complicated debug ... ) way
          `(let ((,logger-symbol ,logger-form))
             (locally (declare (optimize (safety 0) (debug 0) (speed 3)))
               (is-enabled-for ,logger-symbol ,level)))))))

(defun substr (seq from &optional (to (length seq)))
  (declare (fixnum from to)
           (vector seq))
  (make-array (- to from) :element-type (array-element-type seq)
                          :displaced-to seq :displaced-index-offset from))

(defun log-with-logger (logger level log-func)
  "Submit message to logger appenders, and its parent logger"
  (let ((*log-event-time* nil))
    (labels ((log-to-logger-appenders (logger orig-logger level log-func)
               (let* ((state (current-state logger))
                      (appenders
                        (logger-state-appenders state)))
                 (dolist (appender appenders)
                   (appender-do-append appender orig-logger level log-func)))
               (let ((parent (logger-parent logger)))
                 (when  parent
                   (log-to-logger-appenders parent orig-logger level log-func)))
               (values)))
      (log-to-logger-appenders logger logger level log-func)
      (values))))

(defun logger-log-level (logger)
  "Return the logger own log level or NIL if unset. Please note that
by default loggers inherit their parent logger log level, see
EFFECTIVE-LOG-LEVEL"
  (declare (type logger logger))
  (logger-state-level
   (current-state logger)))

(defun logger-appenders (logger)
  "Return the list of logger's own appenders. Please note that by
default loggers inherit their parent logger appenders, see
EFFECTIVE-APPENDERS"
  (declare (type logger logger))
  (logger-state-appenders (current-state logger)))

(defun effective-appenders (logger)
  "Return the list of all appenders that logger output could possible go to,
including inherited one"
  (declare (type logger logger))
  (loop for tmp = logger then parent
        as state = (current-state tmp)
        as parent = (logger-parent tmp)
        append (logger-state-appenders state)
        while (and parent (logger-state-additivity state))))

(defun (setf logger-log-level) (level logger)
  "Set logger log level. Returns logger own log level"
  (declare (type logger logger))
  (nth-value 1 (set-log-level logger level)))

(defun logger-additivity (logger)
  "Return logger additivity"
  (declare (type logger logger))
  (logger-state-additivity (current-state logger)))

(defun (setf logger-additivity) (additivity logger)
  "Set logger appender additivity. Returns new additivity"
  (declare (type logger logger))
  (nth-value 1 (set-additivity logger additivity)))

(defun set-log-level (logger level &optional (adjust-p t))
  "Set the log level of a logger. Log level is passed to
MAKE-LOG-LEVEL to determine canonical log level. ADJUST-P controls if
logger effective log level needs to be recalculated, the caller should
NIL doing bulk operations that change the level of many loggers, as to
avoid overhead.

Returns if log level had changed as the 1st value and new level as the
second value."
  (declare (type logger logger))
  (let* ((level (make-log-level level))
         (state (current-state logger))
         (old-level (logger-state-level state))
         (new-level (when (/= level +log-level-unset+) level)))
    (declare (type fixnum level)
             (type logger-state state)
             (type (or null fixnum) old-level new-level))
    (unless (eql old-level new-level)
      (setf (logger-state-level state) new-level)
      (when adjust-p
        (adjust-logger logger))
      (values t new-level))))

(defun set-additivity (logger additivity &optional (adjust-p t))
  "Set logger additivity."
  (declare (type logger logger))
  (let* ((state (current-state logger))
         (old-additivity (logger-state-additivity state)))
    (unless (eql old-additivity additivity)
      (setf (logger-state-additivity state) additivity)
      (when adjust-p (adjust-logger logger))
      (values additivity))))

(defun add-appender (logger appender)
  (declare (type logger logger) (type appender appender))
  (let* ((state (current-state logger)))
    (unless (member appender (logger-state-appenders state))
      (push appender (logger-state-appenders state))
      (adjust-logger logger)))
  (values))

(defun logger-name (logger)
  "Return the name of the logger category itself (without parent loggers)"
  (substr (logger-category logger)
          (logger-name-start-pos logger)))

(defun logger-name-length (logger)
  "Return length of logger itself (without parent loggers)"
  (- (length (logger-category logger))
     (logger-name-start-pos logger)))

(defun %hierarchy-index (name)
  (when (stringp name)
    (setq name (intern name)))
  (let ((index (gethash name *name-to-hierarchy*)))
    (unless index
      (with-recursive-lock-held (*hierarchy-lock*)
        (adjust-all-loggers-state (1+ *hierarchy-max*))
        (setf index *hierarchy-max*)
        (setf (gethash name *name-to-hierarchy*) index)
        (incf *hierarchy-max*)))
    index))

(defun hierarchy-index (hierarchy)
  "Return the hierarchy index for the specified hierarchy. Hierarchy
must be already a number or a unique identifier suitable for comparing
using EQL. If hierarchy is a string, it will be interned in the current
package"
  (if (numberp hierarchy) hierarchy
      (%hierarchy-index hierarchy)))

(defun adjust-all-loggers-state (new-len)
  (labels ((doit (logger)
             (declare (type logger logger))
             (let ((tmp (adjust-array (logger-state logger)
                                      new-len
                                      :element-type 'logger-state)))
               (setf (svref tmp (1- new-len)) (make-logger-state)
                     (logger-state logger) tmp)
               (map-logger-children #'doit logger))))
    (doit *root-logger*))
  (values))


(defun clear-logging-configuration ()
  "Delete all loggers"
  (labels ((reset (logger)
             (setf (svref (logger-state logger) *hierarchy*)
                   (make-logger-state))
             (map-logger-children #'reset logger)))
    (reset *root-logger*))
  (values))

(defun reset-logging-configuration ()
  "Clear the logging configuration in the current hierarchy, and
configure root logger with INFO log level and a simple console
appender"
  (clear-logging-configuration)
  (add-appender *root-logger* (make-instance 'console-appender))
  (setf (logger-log-level *root-logger*) +log-level-info+))

(defun create-root-logger ()
  (let ((root (create-logger :category "" :category-separator "")))
    (adjust-logger root)
    root))

(defvar *root-logger*
  (create-root-logger)
  "The one and only root logger")

(defmethod make-load-form ((log logger) &optional env)
  "Creates the logger when a logger constant is being loaded from a
compiled file"
  (declare (ignore env))
  `(get-logger ,(logger-category log)))

(defun log-event-time ()
  "Returns the universal time of the current log event"
  (locally (declare (optimize (safety 0) (debug 0) (speed 3)))
    (or *log-event-time* (setq *log-event-time* (get-universal-time)))))
