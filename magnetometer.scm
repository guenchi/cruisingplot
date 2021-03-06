;; Copyright (C) 2010, 2012 Sean D'Epagnier <sean@depagnier.com>
;;
;; This Program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public
;; License as published by the Free Software Foundation; either
;; version 3 of the License, or (at your option) any later version.

;; This file handles reading from a magnetometer (and optional additional accelerometer sensors)
;; raw data of the digitalsurveyinstruments design

(declare (unit magnetometer))
(declare (uses sensor leastsquares quaternion))

(use gl glu glut)

(include "glshortcuts.scm")

; (load "utilities.scm") (load "leastsquares.scm") (load "vector.scm") (load "matrix.scm") (load "algebra.scm")

;(define accel-mag-3d-calibration #f)

(define accel-mag-3d-calibration
  '((1     0  0 1   0  0 0 1 0
    1 0 0 0  0 1 0 0  0 0 1 0
    .9) 1))

(define calibration-measurements '())

(define (recompute-calibration)
  (if (> (length calibration-measurements) 10)
      (set! accel-mag-3d-calibration
            (calibrate-accel-mag-3d
             (map (lambda (m)
                    (append (second m) (third m)))
                  calibration-measurements)))))

(define (save-calibration filename)
  (cond ((not (equal? filename "none"))
         (verbose "saving magnetometer calibration to " filename)
         (with-output-to-file filename
           (lambda () (write calibration-measurements))))))

(define (load-calibration filename)
  (if (equal? filename "none")
      (verbose "not loading calibration for magnetometer")
      (call/cc (lambda (bail)
                (verbose "loading magnetometer calibration from " filename)
                (with-exception-handler
                 (lambda _ (verbose "failed to open file " filename
                                    " for reading, magnetometer calibration empty")
                         (bail #f))
                 (lambda ()
                   (with-input-from-file filename
                     (lambda () (set! calibration-measurements (read))))))))))

(define (add-measurement measurement)
  (set! calibration-measurements (cons measurement calibration-measurements)))

(define (calibrated-calibration-measurements)
  (map (lambda (measurement)
         (let ((time (first measurement))
               (accel (second measurement))
               (mag (third measurement)))
           (cons time (apply-accel-mag-3d accel mag accel-mag-3d-calibration))))
       calibration-measurements))

; remove find how far a measurement is from norm (magnitude 1) and divide this
; by the distance when normalized to the nearest normalized calibration point.  The greatest value here
; is worst and should be removed.

(define (normalize-measurements calibrated-calibration-measurements)
  (map (lambda (measurement)
         (cons (car measurement) (map normalize (cdr measurement))))
       calibrated-calibration-measurements))

;c-calaccel: (1.008 -0.106 0.004 1.002 -0.043 -0.002 -0.001 1.006 0.02)
;c-calmag  : (0.889 -0.049 -0.013 -0.165 -0.035 0.853 -0.002 0.476 -0.025 -0.051 0.961 -0.333)
;c-caldip  : 67.046 err 0.044

(define (min-dist-cal-point normalized-calibrated-measurement
                            normalized-calibrated-calibration-measurements)
  (let ((norm-cal-accel (second normalized-calibrated-measurement))
        (norm-cal-mag (third normalized-calibrated-measurement)))
    (let each-minimum ((min-dist-accel #f)
                       (min-dist-mag #f)
                       (measurements normalized-calibrated-calibration-measurements))
      (cond ((null? measurements)
             (list min-dist-accel min-dist-mag))
            (else
             (let ((cur-norm-cal-accel (second (car measurements)))
                   (cur-norm-cal-mag (third (car measurements))))
               (let ((dist-accel (distance norm-cal-accel cur-norm-cal-accel))
                     (dist-mag (distance norm-cal-mag cur-norm-cal-mag)))
                 (if (and (not (zero? dist-accel))
                          (not (zero? dist-mag))
                          (or (not min-dist-accel) (not min-dist-mag)
                              (< (+ (square dist-accel) (square dist-mag))
                                 (+ (square min-dist-accel) (square min-dist-mag)))))
                     (each-minimum dist-accel dist-mag
                                   (cdr measurements))
                     (each-minimum min-dist-accel min-dist-mag
                                   (cdr measurements))))))))))

(define (compute-culling-metric calibrated-measurement
                                normalized-calibrated-measurement
                                normalized-calibrated-calibration-measurements)
  (let ((time (first calibrated-measurement))
        (cal-accel (second calibrated-measurement))
        (cal-mag (third calibrated-measurement)))
    (let-values (((min-dist-accel min-dist-mag)
                  (apply values
                         (min-dist-cal-point normalized-calibrated-measurement
                                             normalized-calibrated-calibration-measurements))))
      (if (or (not min-dist-accel) (not min-dist-mag))
          (error "min dist not achieved"))
      (if (< (- (elapsed-seconds) time) 10)
          0
          (let ((ane (- 1 (magnitude cal-accel)))
                (mne (- 1 (magnitude cal-mag)))
                (dipe (+ (last (first accel-mag-3d-calibration))
                         (dot norm-cal-accel norm-cal-mag))))
;            (print "ane " ane " mne " mne " dipe " dipe " mda " min-dist-accel " mdm " min-dist-mag)
            (if (or (> min-dist-accel .15) (> min-dist-mag .15))
                (/ (+ (square ane) (square mne) (square dipe)) 10)
                (+ (square ane) (square mne) (square dipe))))))))

(define (cull-calibration-measurements)
  (let*((calibrated-calibration-measurements (calibrated-calibration-measurements))
        (normalized-calibrated-calibration-measurements
         (normalize-measurements calibrated-calibration-measurements))
    ; compute magnitudes and nearest-distance for each measurement
        (measurements-with-metric
         (map (lambda (measurement calibrated-measurement normalized-calibrated-measurement)
                (list measurement
                      (compute-culling-metric
                       calibrated-measurement
                       normalized-calibrated-measurement
                       normalized-calibrated-calibration-measurements)))
                calibration-measurements
                calibrated-calibration-measurements
                normalized-calibrated-calibration-measurements))
; sort measurements based on metric
        (sorted-metric-measurements
         (sort measurements-with-metric
               (lambda (a b) (> (second a) (second b)))
               )))
    (verbose "culling measurement " (map-round-to-places (first (first sorted-metric-measurements)) 2)
             " metric " (second (first sorted-metric-measurements)) )
    (set! calibration-measurements (cdr (map first sorted-metric-measurements)))))

(define (update-calibration-measurements accel mag options)
  (let ((measurement (list (elapsed-seconds) accel mag)))
    (cond ((not (or (any not accel) (any not mag)))
           (if accel-mag-3d-calibration
               (let-values (((min-dist-accel min-dist-mag)
                             (apply values
                              (min-dist-cal-point
                               (cons (car measurement)
                                     (map normalize
                                          (apply-accel-mag-3d accel mag
                                                              accel-mag-3d-calibration)))
                               (normalize-measurements (calibrated-calibration-measurements))))))
;                 (print "min-dist-accel " min-dist-accel " min-dist-mag " min-dist-mag)
                 (if (or (not min-dist-accel) (not min-dist-mag)
                         (and (> min-dist-accel .01) (> min-dist-mag .01)))
                     (add-measurement measurement))))
             (if (>= (length calibration-measurements) (options 'max-calibration-points))
                 (cull-calibration-measurements))))))

(define (generate-calibration-measurements count v)
  (let ((sd 1.2) (abd .2) (acd .05) (mbd 1) (mcd .2))
    (let ((nsd (+ 2 (- sd))) (nabd (- abd))
          (nacd (- acd)) (nmbd (- mbd)) (nmcd (- mcd)))
  (let ((a (random-in-range nsd sd)) (b (random-in-range nabd abd))
        (c (random-in-range nacd acd)) (d (random-in-range nsd sd))
        (e (random-in-range nabd abd))
        (f (random-in-range nacd acd)) (g (random-in-range nacd acd))
        (h (random-in-range nsd sd)) (i (random-in-range nabd abd))
        (j (random-in-range nsd sd)) (k (random-in-range nmcd mcd))
        (l (random-in-range nmcd mcd)) (m (random-in-range nmbd mbd))
        (n (random-in-range nmcd mcd)) (o (random-in-range nsd sd))
        (p (random-in-range nmcd mcd)) (q (random-in-range nmbd mbd))
        (r (random-in-range nmcd mcd)) (s (random-in-range nmcd mcd))
        (t (random-in-range nsd sd)) (u (random-in-range nmbd mbd)))
    (print (map-round-to-places
            (list  "a: " a " b: " b " c: " c " d: " d " e: " e " f: " f " g: " g
                  " h: " h " i: " i " j: " j " k: " k " l: " l " m: " m " n: " n
                  " o: " o " p: " p " q: " q " r: " r " s: " s " t: " t " u: " u " v: " v) 3))
    (define (generate-calibration-measurement cax cay caz cmx cmy cmz)
; ax = (cax-b)/a
; ay = -(a*(e-cay)+c*cax-b*c)/(a*d)
; az = -(a*(d*(i-cz)-e*g+cy*g)+b*(c*g-d*f)+cx*(d*f-c*g))/(a*d*h)
;
; dem = (j*(p*s-o*t)+k*(n*t-p*r)+l*(o*r-n*s))
; mx = -(l*(o*(u-cmz)-q*s+cmy*s)+k*(p*(cmz-u)+q*t-cmy*t)+cmx*(o*t-p*s)+m*(p*s-o*t))
;      /dem
; my = (l*(n*(u-cmz)-q*r+cmy*r)+j*(p*(cmz-u)+q*t-cmy*t)+cmx*(n*t-p*r)+m*(p*r-n*t))
;      /dem      
; mz = -(k*(n*(u-cmz)-q*r+cmy*r)+j*(o*(cmz-u)+q*s-cmy*s)+cmx*(n*s-o*r)+m*(o*r-n*s))
;      /dem
      (list
         (list (/ (- cax b) a)
               (- (/ (- (+ (* a (- e cay)) (* c cax)) (* b c)) (* a d)))
               (- (/ (+ (* a (+ (- (* d (- i caz)) (* e g)) (* cay g)))
                        (* b (- (* c g) (* d f))) (* cax (- (* d f) (* c g)))) (* a d h))))
     (let ((dem (+ (* j (- (* p s) (* o t))) (* k (- (* n t) (* p r))) (* l (- (* o r) (* n s))))))
       (list (/ (- (+ (* l (+ (- (* o (- u cmz)) (* q s)) (* cmy s)))
                      (* k (- (+ (* p (- cmz u)) (* q t)) (* cmy t)))
                      (* cmx (- (* o t) (* p s))) (* m (- (* p s) (* o t)))))
                dem)
             (/ (+ (* l (+ (- (* n (- u cmz)) (* q r)) (* cmy r)))
                   (* j (- (+ (* p (- cmz u)) (* q t)) (* cmy t)))
                   (* cmx (- (* n t) (* p r))) (* m (- (* p r) (* n t))))
                dem)
             (/ (- (+ (* k (+ (- (* n (- u cmz)) (* q r)) (* cmy r)))
                      (* j (- (+ (* o (- cmz u)) (* q s)) (* cmy s)))
                      (* cmx (- (* n s) (* o r))) (* m (- (* o r) (* n s)))))
                dem)))))
    (map (lambda (index)
      (let*((accel (random-normalized-vector 3))
            (rand-orthogonal (vector-cross accel (random-normalized-vector 3)))
            (accel-to-mag-quaternion (angle-vector->quaternion (acos (- v)) rand-orthogonal))
            (mag (apply-quaternion-to-vector accel-to-mag-quaternion accel)))
        (cons index
              (let ((rn -.002) (rp .002))
                (map vector+
                     (list (list (random-in-range rn rp) (random-in-range rn rp) (random-in-range rn rp))
                           (list (random-in-range rn rp) (random-in-range rn rp) (random-in-range rn rp)))
                   (generate-calibration-measurement (first accel) (second accel) (third accel)
                                                     (first mag) (second mag) (third mag)))))))
         (sequence 1 count))))))

(define (test-algorithms)
  (let ((meas (generate-calibration-measurements 64 .5)))
    (print "meas " (map-round-to-places meas 3))
    (let ((cal (compute-accelerometer-calibration (map second meas))))
      (print "accel-cal "  (map-round-to-places cal 3)))
    (let ((cal (compute-magnetometer-calibration (map third meas))))
      (print "mag-cal "  (map-round-to-places cal 3)))
    (let ((cal (calibrate-sensor-3d (map second meas))))
      (print "accel-sensor-cal "  (map-round-to-places cal 4)))
    (let ((cal (calibrate-sensor-3d (map third meas))))
      (print "mag-sensor-cal "  (map-round-to-places cal 4)))
    (let ((cal (calibrate-basic-accel-mag-3d (map (lambda (m)
                                                    (append (second m) (third m))) meas))))
      (print "basic-accel-mag-cal "  (map-round-to-places cal 3)))
    (let ((cal (calibrate-accel-mag-3d (map (lambda (m)
                                              (append (second m) (third m))) meas))))
      (print "accel-mag-cal "  (map-round-to-places cal 3)))
    (exit 1)))
                      
(define (magnetometer-setup arg)
  (define options
    (create-options
     `(,(make-number-verifier 'max-calibration-points "number of calibration points to use" 48 0 1000)
       ,(make-boolean-verifier 'disable-updates "disable runnign calibration updates" 'false)
       ,(make-string-verifier 'calibration-file
                              "file to use for saving and loading calibration between runs" "magcal"))
     "currently the magnetometer supports the first 3 axes of accelerometer and magnetometer sensors"
     #f))

  (parse-basic-options-string options arg)
  (load-calibration (options 'calibration-file))

;  (test-algorithms)
  (recompute-calibration)

  (cond ((not (options 'disable-updates))

  (define accel-read '(0 0 0))
  (define default-accel-read-max '(-2 -2 -2))
  (define accel-read-max default-accel-read-max)
  (define default-accel-read-min '(2 2 2))
  (define accel-read-min default-accel-read-min)

  (define mag-read '(0 0 0))
  (define default-mag-read-max '(-2 -2 -2))
  (define mag-read-max default-mag-read-max)
  (define default-mag-read-min '(2 2 2))
  (define mag-read-min default-mag-read-min)

  (define sensor-read-count 0)

  (create-periodic-task
   "magnetometer-sensor-reader" .1
   (lambda ()
     (let ((accel (map sensor-query (map (lambda (n) (list 'accel n)) '(0 1 2))))
           (mag (map sensor-query (map (lambda (n) (list 'mag n)) '(0 1 2)))))
       (cond ((and accel mag (not (any not accel)) (not (any not mag)))
              (set! accel-read (vector+ accel-read accel))
              (set! accel-read-max (map max accel-read-max accel))
              (set! accel-read-min (map min accel-read-min accel))
              (set! mag-read (vector+ mag-read mag))
              (set! mag-read-max (map max mag-read-max mag))
              (set! mag-read-min (map min mag-read-min mag))
              (set! sensor-read-count (+ 1 sensor-read-count)))))))

  (let ((save-counter 0))
  (create-periodic-task
   "magnetometer-calibration" 2
   (lambda ()
     (if (> sensor-read-count 5)
         (let ((accel-avg (vector-scale (/ sensor-read-count) accel-read))
               (mag-avg (vector-scale (/ sensor-read-count) mag-read)))
           (let ((accel-dev (magnitude (vector- accel-read-max accel-read-min)))
                 (mag-dev (magnitude (vector- mag-read-max mag-read-min))))
;             (print "accel-dev " accel-dev " mag-dev " mag-dev)
             (cond ((and (>= sensor-read-count 30) (< accel-dev .02) (< mag-dev .01))
                    (print "update-cal " (map-round-to-places accel-avg 3)
                           " " (map-round-to-places mag-avg 3))
                    (update-calibration-measurements accel-avg mag-avg options)))
             (cond ((or (>= sensor-read-count 30) (> accel-dev .02) (> mag-dev .01))
                    (set! accel-read '(0 0 0))
                    (set! accel-read-max default-accel-read-max)
                    (set! accel-read-min default-accel-read-min)
                    (set! mag-read '(0 0 0))
                    (set! mag-read-max default-mag-read-max)
                    (set! mag-read-min default-mag-read-min)
                    (set! sensor-read-count 0))))))

     (let ((accel (map sensor-query (map (lambda (n) (list 'accel n)) '(0 1 2))))
           (mag (map sensor-query (map (lambda (n) (list 'mag n)) '(0 1 2)))))

       (cond ((>= (length calibration-measurements) 10)
              (let ((accel-cal (calibrate-sensor-3d (map second calibration-measurements))))
                (verbose "accel-sensor-cal "  (map-round-to-places accel-cal 4)))
              (let ((accel-cal (calibrate-sensor-3rd-order-3d (map second calibration-measurements))))
                (verbose "accel-sensor-3rd-order-cal "  (map-round-to-places accel-cal 4)))
              (let ((mag-cal (calibrate-sensor-3d (map third calibration-measurements))))
                (verbose "mag-sensor-cal "  (map-round-to-places mag-cal 4)))
              (let ((mag-cal (calibrate-sensor-3rd-order-3d (map third calibration-measurements))))
                (verbose "mag-sensor-3rd-order-cal "  (map-round-to-places mag-cal 4)))

              (recompute-calibration)

              (if (and accel mag (not (any not accel)) (not (any not mag)))
                  (verbose "pitch " (round-to-places (computation-calculate 'pitch) 2)
                           " roll " (round-to-places (computation-calculate 'roll) 2)
                           " heading " (round-to-places (computation-calculate 'magnetic-heading) 2)
                           " dip " (round-to-places (computation-calculate 'magnetic-inclination) 2)))

           (let-values (((a b c d e f g h i j k l m n o p q r s t u v)
                         (apply values (first accel-mag-3d-calibration))))
             (verbose "c-calaccel: " (map-round-to-places `(,a ,b ,c ,d ,e ,f ,g ,h ,i) 3))
             (verbose "c-calmag  : " (map-round-to-places `(,j ,k ,l ,m ,n ,o ,p ,q ,r ,s ,t ,u) 3))
             (verbose "c-caldip  : " (round-to-places (rad2deg (asin v)) 3)
                    " err " (round-to-places (second accel-mag-3d-calibration) 3)))
           (if (and accel mag (not (any not accel)) (not (any not mag)))
               (let ((d (apply-accel-mag-3d accel mag accel-mag-3d-calibration)))
                 (verbose "caccel " (map-round-to-places (first d) 2)
                          " cm " (round-to-places (magnitude (first d)) 2)
                          " cmag " (map-round-to-places (second d) 2)
                          " cm " (round-to-places (magnitude (second d)) 2))
                 (let ((pitch (deg2rad (accelerometer-pitch (first d))))
                       (roll  (deg2rad (accelerometer-roll (first d)))))
                   (let ((mx (first (second d)))
                         (my (second (second d)))
                         (mz (third (second d))))
                        (let ((xh (+ (* mx (cos pitch))
                                     (* mz (sin pitch))))
                              (yh (+ (* mx (sin roll) (sin pitch))
                                     (* my (cos roll))
                                     (* -1 mz (sin roll) (cos pitch)))))
                          (let ((yaw (atan yh xh)))
                 (print "cpitch " (round-to-places (accelerometer-pitch (first d)) 2)
                        " croll " (round-to-places (accelerometer-roll (first d)) 2)
                        " cyaw "  (round-to-places (apply magnetometer-heading d) 2)
                        " new-yaw " (round-to-places (rad2deg yaw) 2)
                        " cinc "  (round-to-places (apply magnetometer-inclination d) 2))))) 
                  ))))))

       (cond ((>= save-counter 100)
              (save-calibration (options 'calibration-file))
              (set! save-counter 0))
             (else
              (set! save-counter (+ save-counter 1))))
       ))))))

(computation-register 'pitch "The pitch derived from the accelerometer" '(accel)
                      (lambda ()
                        (if (not accel-mag-3d-calibration)
                            #f
                            (let*((accel (sensor-query-indexes 'accel '(0 1 2)))
                                  (cal-accel (first (apply-accel-mag-3d accel '(0 0 0)
                                                                        accel-mag-3d-calibration))))
                              (accelerometer-pitch cal-accel)))))

(computation-register 'roll "The roll derived from the accelerometer" '(accel)
                      (lambda ()
                        (if (not accel-mag-3d-calibration)
                            #f
                            (let*((accel (sensor-query-indexes 'accel '(0 1 2)))
                                  (cal-accel (first (apply-accel-mag-3d accel '(0 0 0)
                                                                        accel-mag-3d-calibration))))
                                (accelerometer-roll cal-accel)))))

(computation-register 'magnetic-heading "The heading derived from the magnetometer" '(mag accel)
                      (lambda ()
                          (let ((accel (sensor-query-indexes 'accel '(0 1 2)))
                                (mag (sensor-query-indexes 'mag '(0 1 2))))
                            (if (not accel-mag-3d-calibration)
                                #f
                                (let ((cal (apply-accel-mag-3d accel mag accel-mag-3d-calibration)))
                                  (magnetometer-heading (first cal) (second cal)))))))

(computation-register 'magnetic-inclination "The inclination derived from the magnetometer" '(mag accel)
                      (lambda ()
                          (let ((accel (sensor-query-indexes 'accel '(0 1 2)))
                                (mag (sensor-query-indexes 'mag '(0 1 2))))
                            (if (not accel-mag-3d-calibration)
                                #f
                                (let ((cal (apply-accel-mag-3d accel mag accel-mag-3d-calibration)))
                                  (magnetometer-inclination (first cal) (second cal)))))))

(computation-register
 'heading "The true heading derived from the magnetometer and declination, if no magnetometer is specified, gps heading is used" '(gps)
 (lambda ()
    (if (sensor-contains? 'mag)
        (- (computation-calculate 'magnetic-heading)
           (computation-calculate 'declination))
        (begin (warning-once "using gps heading for heading, "
                             "this may be very inaccurate.")
               (computation-calculate 'gps-heading)))))

(computation-register 'acceleration-magnitude "The magnitude of force" '(accel)
                      (lambda () (magnitude (sensor-query-indexes 'accel '(0 1 2)))))

(computation-register 'magnetic-magnitude "The magnitude of the field" '(mag)
                      (lambda () (magnitude (sensor-query-indexes 'mag '(0 1 2)))))

; rotate vec by whatever rotation is needed to make align axis
(define (align-axis vec align axis)
  (apply-quaternion-to-vector (vector-vector->quaternion align axis) vec))

; give mag coordinates so we can calculate yaw with atan on x and y
(define (rotate-out-mag accel mag)
    (let ((v1 (normalize accel))
          (v2 (normalize `(0 ,(second accel) ,(third accel)))))
      (align-axis (align-axis mag v1 v2) v2 '(0 0 1))))

(define (accelerometer-pitch accel)
  (rad2deg (- (atan (first accel)
                          (sqrt (+ (square (second accel))
                                   (square (third accel))))))))

; compute the roll angle from accel reading
(define (accelerometer-roll accel)
  (rad2deg (atan (second accel) (third accel))))

; given vectors for accel and mag, determine yaw direction of x axis
(define (magnetometer-heading accel mag)
  (let ((rmag (rotate-out-mag accel mag)))
    (rad2deg (phase-resolve-positive (atan (second rmag) (first rmag))))))

; given vectors for accel and mag, determine angle between them
(define (magnetometer-inclination accel mag)
  (rad2deg (- (/ Pi 2) (phase-resolve (acos (dot (normalize accel)
                                                 (normalize mag)))))))

; we know boat moves with a time constant.  try to lock on to this for
; each sensor input so we can cancel it
; 
; x = bias + amplitude*sin(2*Pi*t*frequency + phase)
;
; states: bias amplitude period phase
; measurements: x t
(define (calibrate-sensor-boat-motion measurements)
  (let ((cal
         (least-squares-iterate
          `(,(apply average (map first measurements)) 1 .25 0)
          (lambda (state measurement)
            (let-values (((bias amplitude frequency phase) (apply values state))
                         ((x t) (apply values measurement)))
              (let ((a (+ (* (* 2 Pi t) frequency) phase)))
                (let ((val
                       (list (list 1
                                   (sin a)
                                   (* 2 Pi amplitude t (cos a))
                                   (* amplitude (cos a)))
                             (- x (+ bias (* amplitude (sin a)))))))
                  (print "val " val " state " state " measurement " measurement)
                  val))))
          measurements
          (lambda (state update)
            (< update 1e-3))
          2)))
    (let ((state (first cal)) (update (second cal)))
      (if (< update 1)
          (let-values (((bias amplitude frequency phase) (apply values state)))
            (list bias (abs amplitude) frequency
                  (phase-resolve (if (negative? amplitude) (+ phase Pi) phase))))
          #f))))


(define (test-calibration-constraints value constraints)
  (cond ((null? value) #t)
        ((not (first value)) #t)
        ((< (first value) (first (first constraints))) #f)
        ((> (first value) (second (first constraints))) #f)
        (else (test-calibration-constraints (cdr value) (cdr constraints)))))

; a completely calibrated 3 axis sensor has states for:
;
; xb yb zb (biases) s (scale to 1 earth field) yrs zrs (relative scales for y and z)
; xyc xzc yzc (cross coupling coefficients alignment of axes etc..)
;
; when states are set to #f then not enough data to determine them exists

(define (apply-accelerometer-calibration calibration measurement)
  (if (and calibration (not (any not measurement)))
      (let-values (((xb yb zb s) (apply values (first calibration)))
                   ((x y z) (apply values measurement)))
        (vector-scale (/ s) (vector- measurement (first calibration))))
      #f))

(define (compute-accelerometer-calibration measurements)
  (let ((cal (calibrate-biases-and-scale-3d measurements)))
    (if (test-calibration-constraints
         (first cal) '((-2 2) (-2 2) (-2 2) (.2 2)))
        cal #f)))

(define (apply-magnetometer-calibration calibration measurement)
  (if (and calibration (not (any not measurement)))
      (let-values (((xb yb zb s yrs zrs xyc xzc yzc) (apply values (first calibration)))
                   ((x y z) (apply values measurement)))
        (vector-scale (/ s)
                      (let-values (((xs ys zs) (apply values (vector- measurement (first calibration)))))
                        (cond ((not yrs) `(,xs ,ys ,zs))
                              ((not xyc) `(,xs
                                           ,(* yrs ys)
                                           ,(* zrs zs)))
                              (else `(,xs
                                      ,(* yrs (+ ys (* xyc xs)))
                                      ,(* zrs (+ zs (* xzc xs) (* yzc ys)))))))))
        #f))

(define (compute-magnetometer-calibration measurements)
  (let ((cal
         (let ((cal1 (calibrate-biases-and-scale-3d measurements))
               (cal2 (calibrate-biases-scale-and-relative-scales-3d measurements))
               (cal3 (calibrate-biases-scale-relative-scales-and-cross-coupling-3d measurements))
               (really-big 1e100))
           (let ((c1d (if cal1 (second cal1) really-big))
                 (c2d (if cal2 (second cal2) really-big))
                 (c3d (if cal3 (second cal3) really-big)))
             (let ((mc (min c1d c2d c3d)))
               (cond ((= really-big mc) #f)
                     ((= c1d mc) (list (append (first cal1) (make-list 5)) (second cal1)))
                     ((= c2d mc) (list (append (first cal2) (make-list 3)) (second cal2)))
                     ((= c3d mc) (list (append (first cal3) (make-list 0)) (second cal3)))
                     (else (error "this should not happen"))))))))
    (if (test-calibration-constraints
         (first cal) '((-2 2) (-2 2) (-2 2) (.2 2) (.2 2) (.2 2) (-.8 .8) (-.8 .8) (-.8 .8)))
        cal #f)))


; magnetometer alignment calibration...
;
; dip (magnetic declination)
; rvx rvy rvz (rotation vector, rotate magnetometer coordinates around this by its magnitude in radians)

(define (refine-measurements measurements measurement)
  (cond ((any (lambda (m) (equal? m measurement)) measurements)
         measurements)
        ((< (length measurements) 64)
         (cons measurement measurements))
        (else
         (let ((dist-map
             (sort (map
                    (lambda (m1)
                      (list
                       (apply min
                              (map (lambda (m2)
                                     (distance m1 m2))
                                   (let each-m ((measurements measurements))
                                     (cond ((null? measurements) '())
                                           ((eq? (car measurements) m1) (each-m (cdr measurements)))
                                           (else (cons (car measurements) (each-m (cdr measurements))))))))
                       m1))
                    measurements)
                   (lambda (a b) (< (car a) (car b))))))
;        (print "dist-map " dist-map)
;        (newline)
        (cons measurement (cdr (map second dist-map)))))))

(define (magnetometer-test-data1 filename)
  (with-input-from-file filename
    (lambda ()
      (let each-line ((n 0)
                      (measurements '()))
        (let ((line (read-line)))
          (cond ((eof-object? line)
                 (let ((cal1 (calibrate-biases-and-scale-3d measurements))
                       (cal2 (calibrate-biases-scale-and-relative-scales-3d measurements))
                       (cal3 (calibrate-biases-scale-relative-scales-and-cross-coupling-3d measurements)))
                   (print "measurements " measurements)
                   (print "cal1 " cal1)
                   (print "cal2 " cal2)
                   (print "cal3 " cal3)
                   (exit 0)))
                (else
                 (let-values (((time ax ay az gx gy gz mx my mz temp)
                               (apply values (string-split line ", "))))
                   (if (zero? (remainder n 20000))
                       (print "on line " n))
                   (each-line (+ n 1)
                              (if (and (> n 537400) (< n 800000))
                                  (refine-measurements measurements
                                                       (list
                                                        (/ (string->number mx) 512)
                                                        (/ (string->number my) 512)
                                                        (/ (string->number mz) 512)))
                                  measurements))))))))))

(define (cull-bad-measurements measurements cal)
  (let ((bias-vec (list (first (first cal)) (second (first cal)) (third (first cal)))))
    (let each-measurement ((measurements measurements))
    (cond ((null? measurements) '())
          ((> (abs (- (/ (magnitude (vector- (car measurements) bias-vec))
                         (fourth (first cal))) 1)) .04)
           (each-measurement (cdr measurements)))
          (else (cons (car measurements) (each-measurement (cdr measurements))))))))

(define (magnetometer-test-data filename)
  (let*((measurements (with-input-from-file filename read))
        (cal (calibrate-biases-and-scale-3d measurements))
        (updated-measurements (cull-bad-measurements measurements cal)))
    (let ((cal1 (calibrate-biases-and-scale-3d updated-measurements))
          (cal2 (calibrate-biases-scale-and-relative-scales-3d updated-measurements))
          (cal3 (calibrate-biases-scale-relative-scales-and-cross-coupling-3d updated-measurements)))

      (print "measurements " (length measurements) " updated " (length updated-measurements))
      (print "cal " cal)
      (print "cal1 " cal1)
      (print "cal2 " cal2)
      (print "cal3 " cal3)

      (glut:InitDisplayMode (+ glut:DOUBLE glut:RGB glut:ALPHA))
      (glut:CreateWindow "magnetomter plot")
      (glut:DisplayFunc
       (let ((ang1 0) (ang2 0))
         (lambda ()
           (gl:Clear gl:COLOR_BUFFER_BIT)  
           (gl:MatrixMode gl:MODELVIEW)
           (gl:LoadIdentity)

           (RotateAfter ang1 0 1 0)
           (set! ang1 (+ ang1 1))
           (RotateAfter ang2 1 0 0)
           (set! ang2 (+ ang2 .2))
           
           (TranslateAfter 0 0 -2)
           
           (glColor 1 1 1)
           (glBegin gl:POINTS
                    (for-each (lambda (measurement)
                                (apply glVertex measurement))
                              updated-measurements))

           (glColor .2 0 1)
           (let-values (((bx by bz s) (apply values (first cal1))))
             (gl:Translated bx by bz)
             (glut:WireSphere s 32 16))

           (glut:SwapBuffers)
           (thread-sleep! .1)
           (glut:PostRedisplay))))

    (glut:KeyboardFunc
     (lambda (key x y)
       (case key
         ((#\esc #\q) (exit))
         ((#\f) (glut:FullScreenToggle)))
       (glut:PostRedisplay)))

      (glut:ReshapeFunc
       (lambda (w h)
         (gl:Viewport 0 0 w h)
         (gl:MatrixMode gl:PROJECTION)
         (gl:LoadIdentity)
         (glu:Perspective 90 (/ w h) .1 100)))

      (glut:IdleFunc (lambda () (thread-sleep! .01) ))
      (glut:MainLoop)

      (exit 0))))
