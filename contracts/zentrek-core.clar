;; zentrek-core.clar
;; ZenTrek Mindfulness Protocol Core Contract
;;
;; This contract implements the core functionality of the ZenTrek mindfulness platform,
;; managing user registrations, subscriptions, practice tracking, content access, and
;; reward distribution for the decentralized mindfulness application on Stacks.

;; ========================================
;; Constants and Error Codes
;; ========================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-USER-ALREADY-EXISTS (err u101))
(define-constant ERR-USER-NOT-FOUND (err u102))
(define-constant ERR-INVALID-SUBSCRIPTION (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-SUBSCRIPTION-ACTIVE (err u105))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u106))
(define-constant ERR-CONTENT-NOT-FOUND (err u107))
(define-constant ERR-ALREADY-PRACTICED-TODAY (err u108))
(define-constant ERR-CONTENT-ALREADY-EXISTS (err u109))
(define-constant ERR-INVALID-PARAMETERS (err u110))

;; Subscription tiers and pricing
(define-constant TIER-BASIC u1)
(define-constant TIER-PREMIUM u2)
(define-constant TIER-UNLIMITED u3)

(define-constant BASIC-PRICE u10000000) ;; 10 STX
(define-constant PREMIUM-PRICE u25000000) ;; 25 STX
(define-constant UNLIMITED-PRICE u50000000) ;; 50 STX

;; Platform fee percentage (30%)
(define-constant PLATFORM-FEE-PERCENT u30)

;; Minimum practice duration (in seconds)
(define-constant MIN-PRACTICE-DURATION u300) ;; 5 minutes

;; ========================================
;; Data Maps and Variables
;; ========================================

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; Track registered users and their profiles
(define-map users principal 
  {
    registered: bool,
    join-date: uint,
    total-sessions: uint,
    total-minutes: uint
  }
)

;; Track user subscriptions
(define-map subscriptions principal 
  {
    tier: uint,
    start-date: uint,
    end-date: uint,
    auto-renew: bool
  }
)

;; Track mindfulness practice streaks
(define-map practice-streaks principal 
  {
    current-streak: uint,
    longest-streak: uint,
    last-practice-date: uint,
    current-week-minutes: uint
  }
)

;; Daily practice records
(define-map daily-practices (tuple (user principal) (date uint))
  {
    completed: bool,
    duration: uint,
    content-id: uint
  }
)

;; Content library
(define-map content-library uint
  {
    title: (string-ascii 64),
    content-type: (string-ascii 20), ;; "nature-sound" or "breathing-exercise"
    creator: principal,
    creation-date: uint,
    premium: bool,
    total-plays: uint,
    total-minutes: uint
  }
)

;; Content creator profiles
(define-map content-creators principal
  {
    registered: bool,
    content-count: uint,
    total-plays: uint,
    total-minutes: uint,
    earned-stx: uint
  }
)

;; Track the next available content ID
(define-data-var next-content-id uint u1)

;; Total platform statistics
(define-data-var total-users uint u0)
(define-data-var total-practices uint u0)
(define-data-var total-practice-minutes uint u0)
(define-data-var total-subscription-revenue uint u0)

;; ========================================
;; Private Functions
;; ========================================

;; Calculate duration until a specific date in days
(define-private (days-until (target-date uint))
  (let
    (
      (current-time (unwrap-panic (get-block-info? time u0)))
      (seconds-per-day u86400)
      (seconds-difference (- target-date current-time))
    )
    (/ seconds-difference seconds-per-day)
  )
)

;; Get the current date in YYYYMMDD format
(define-private (get-current-date)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time u0)))
      (seconds-per-day u86400)
    )
    (/ current-time seconds-per-day)
  )
)

;; Calculate subscription price based on tier
(define-private (get-subscription-price (tier uint))
  (if (is-eq tier TIER-BASIC)
    BASIC-PRICE
    (if (is-eq tier TIER-PREMIUM)
      PREMIUM-PRICE
      (if (is-eq tier TIER-UNLIMITED)
        UNLIMITED-PRICE
        u0
      )
    )
  )
)

;; Calculate creator reward from a practice session
(define-private (calculate-creator-reward (duration uint) (subscription-tier uint))
  (let
    (
      (base-rate (if (is-eq subscription-tier TIER-BASIC)
                    u500 ;; 0.0005 STX per minute for basic tier
                    (if (is-eq subscription-tier TIER-PREMIUM)
                      u1000 ;; 0.001 STX per minute for premium tier
                      u2000 ;; 0.002 STX per minute for unlimited tier
                    )
                 ))
      (minutes (/ duration u60))
      (raw-reward (* minutes base-rate))
      (platform-fee (/ (* raw-reward PLATFORM-FEE-PERCENT) u100))
    )
    (- raw-reward platform-fee)
  )
)

;; Update user streak information after practice
(define-private (update-streak (user principal))
  (let
    (
      (current-date (get-current-date))
      (streak-info (default-to 
                     {
                       current-streak: u0, 
                       longest-streak: u0, 
                       last-practice-date: u0,
                       current-week-minutes: u0
                     } 
                     (map-get? practice-streaks user)))
      (last-practice-date (get last-practice-date streak-info))
      (current-streak (get current-streak streak-info))
      (longest-streak (get longest-streak streak-info))
    )
    (if (is-eq (+ last-practice-date u1) current-date)
      ;; Consecutive day, increase streak
      (let
        (
          (new-streak (+ current-streak u1))
          (new-longest (if (> new-streak longest-streak) new-streak longest-streak))
        )
        (map-set practice-streaks user
          {
            current-streak: new-streak,
            longest-streak: new-longest,
            last-practice-date: current-date,
            current-week-minutes: (get current-week-minutes streak-info)
          }
        )
        (ok new-streak)
      )
      ;; Not consecutive, reset streak to 1
      (begin
        (map-set practice-streaks user
          {
            current-streak: u1,
            longest-streak: longest-streak,
            last-practice-date: current-date,
            current-week-minutes: (get current-week-minutes streak-info)
          }
        )
        (ok u1)
      )
    )
  )
)

;; Check if user has active subscription
(define-private (has-active-subscription (user principal))
  (let
    (
      (sub-info (map-get? subscriptions user))
      (current-time (unwrap-panic (get-block-info? time u0)))
    )
    (if (is-none sub-info)
      false
      (> (get end-date (unwrap-panic sub-info)) current-time)
    )
  )
)

;; Check if content is accessible to user
(define-private (can-access-content (user principal) (content-id uint))
  (let
    (
      (content (map-get? content-library content-id))
      (sub-info (map-get? subscriptions user))
    )
    (if (is-none content)
      false
      (let
        (
          (is-premium (get premium (unwrap-panic content)))
          (has-subscription (has-active-subscription user))
          (subscription-tier (if (is-none sub-info) 
                                u0 
                                (get tier (unwrap-panic sub-info))))
        )
        (or 
          (not is-premium) ;; Free content accessible to all
          (and is-premium has-subscription (>= subscription-tier TIER-PREMIUM)) ;; Premium content for premium subs
        )
      )
    )
  )
)

;; ========================================
;; Read-Only Functions
;; ========================================

;; Get user profile information
(define-read-only (get-user-profile (user principal))
  (map-get? users user)
)

;; Get user subscription information
(define-read-only (get-user-subscription (user principal))
  (map-get? subscriptions user)
)

;; Get user streak information
(define-read-only (get-user-streak (user principal))
  (map-get? practice-streaks user)
)

;; Get content details
(define-read-only (get-content-details (content-id uint))
  (map-get? content-library content-id)
)

;; Get content creator profile
(define-read-only (get-creator-profile (creator principal))
  (map-get? content-creators creator)
)

;; Check if user practiced on a given date
(define-read-only (has-practiced-today (user principal))
  (let
    (
      (current-date (get-current-date))
      (practice-record (map-get? daily-practices {user: user, date: current-date}))
    )
    (if (is-none practice-record)
      false
      (get completed (unwrap-panic practice-record))
    )
  )
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  {
    total-users: (var-get total-users),
    total-practices: (var-get total-practices),
    total-practice-minutes: (var-get total-practice-minutes),
    total-subscription-revenue: (var-get total-subscription-revenue)
  }
)

;; ========================================
;; Public Functions
;; ========================================

;; Register a new user
(define-public (register-user)
  (let
    (
      (user tx-sender)
      (current-time (unwrap-panic (get-block-info? time u0)))
      (existing-user (map-get? users user))
    )
    (if (is-some existing-user)
      ERR-USER-ALREADY-EXISTS
      (begin
        (map-set users user
          {
            registered: true,
            join-date: current-time,
            total-sessions: u0,
            total-minutes: u0
          }
        )
        (var-set total-users (+ (var-get total-users) u1))
        (ok true)
      )
    )
  )
)

;; Purchase a subscription
(define-public (purchase-subscription (tier uint) (auto-renew bool))
  (let
    (
      (user tx-sender)
      (current-time (unwrap-panic (get-block-info? time u0)))
      (existing-user (map-get? users user))
      (existing-sub (map-get? subscriptions user))
      (price (get-subscription-price tier))
      (duration-seconds (* u30 u86400)) ;; 30 days in seconds
    )
    (if (is-none existing-user)
      ERR-USER-NOT-FOUND
      (if (< tier TIER-BASIC)
        ERR-INVALID-SUBSCRIPTION
        (if (> tier TIER-UNLIMITED)
          ERR-INVALID-SUBSCRIPTION
          (if (and 
                (is-some existing-sub) 
                (> (get end-date (unwrap-panic existing-sub)) current-time))
            ERR-SUBSCRIPTION-ACTIVE
            (begin
              ;; Attempt payment
              (let 
                (
                  (payment-result (stx-transfer? price user (as-contract tx-sender)))
                )
                (if (is-err payment-result)
                  ERR-INSUFFICIENT-FUNDS
                  (begin
                    ;; Update subscription
                    (map-set subscriptions user
                      {
                        tier: tier,
                        start-date: current-time,
                        end-date: (+ current-time duration-seconds),
                        auto-renew: auto-renew
                      }
                    )
                    ;; Update platform statistics
                    (var-set total-subscription-revenue 
                      (+ (var-get total-subscription-revenue) price))
                    (ok true)
                  )
                )
              )
            )
          )
        )
      )
    )
  )
)

;; Cancel subscription auto-renewal
(define-public (cancel-subscription-renewal)
  (let
    (
      (user tx-sender)
      (sub-info (map-get? subscriptions user))
    )
    (if (is-none sub-info)
      ERR-USER-NOT-FOUND
      (begin
        (map-set subscriptions user
          (merge (unwrap-panic sub-info) {auto-renew: false})
        )
        (ok true)
      )
    )
  )
)

;; Record a mindfulness practice session
(define-public (record-practice (content-id uint) (duration uint))
  (let
    (
      (user tx-sender)
      (current-date (get-current-date))
      (current-time (unwrap-panic (get-block-info? time u0)))
      (user-info (map-get? users user))
      (content-info (map-get? content-library content-id))
      (already-practiced (has-practiced-today user))
    )
    (if (is-none user-info)
      ERR-USER-NOT-FOUND
      (if (is-none content-info)
        ERR-CONTENT-NOT-FOUND
        (if already-practiced
          ERR-ALREADY-PRACTICED-TODAY
          (if (< duration MIN-PRACTICE-DURATION)
            ERR-INVALID-PARAMETERS
            (if (not (can-access-content user content-id))
              ERR-SUBSCRIPTION-EXPIRED
              (let
                (
                  (content (unwrap-panic content-info))
                  (creator (get creator content))
                  (creator-info (map-get? content-creators creator))
                  (sub-info (map-get? subscriptions user))
                  (sub-tier (if (is-none sub-info) 
                              u0 
                              (get tier (unwrap-panic sub-info))))
                )
                (begin
                  ;; Record the practice
                  (map-set daily-practices {user: user, date: current-date}
                    {
                      completed: true,
                      duration: duration,
                      content-id: content-id
                    }
                  )
                  
                  ;; Update user profile stats
                  (map-set users user
                    (merge (unwrap-panic user-info)
                      {
                        total-sessions: (+ (get total-sessions (unwrap-panic user-info)) u1),
                        total-minutes: (+ (get total-minutes (unwrap-panic user-info)) (/ duration u60))
                      }
                    )
                  )
                  
                  ;; Update content usage stats
                  (map-set content-library content-id
                    (merge content
                      {
                        total-plays: (+ (get total-plays content) u1),
                        total-minutes: (+ (get total-minutes content) (/ duration u60))
                      }
                    )
                  )
                  
                  ;; Update creator stats
                  (if (is-some creator-info)
                    (let
                      (
                        (creator-data (unwrap-panic creator-info))
                        (reward (calculate-creator-reward duration sub-tier))
                      )
                      (map-set content-creators creator
                        (merge creator-data
                          {
                            total-plays: (+ (get total-plays creator-data) u1),
                            total-minutes: (+ (get total-minutes creator-data) (/ duration u60)),
                            earned-stx: (+ (get earned-stx creator-data) reward)
                          }
                        )
                      )
                    )
                    true
                  )
                  
                  ;; Update platform stats
                  (var-set total-practices (+ (var-get total-practices) u1))
                  (var-set total-practice-minutes 
                    (+ (var-get total-practice-minutes) (/ duration u60)))
                  
                  ;; Update streak
                  (update-streak user)
                )
              )
            )
          )
        )
      )
    )
  )
)

;; Register new content
(define-public (register-content (title (string-ascii 64)) 
                               (content-type (string-ascii 20)) 
                               (premium bool))
  (let
    (
      (creator tx-sender)
      (current-time (unwrap-panic (get-block-info? time u0)))
      (content-id (var-get next-content-id))
      (creator-info (map-get? content-creators creator))
    )
    (if (or 
          (not (is-eq content-type "nature-sound")) 
          (not (is-eq content-type "breathing-exercise")))
      ERR-INVALID-PARAMETERS
      (begin
        ;; Register the content
        (map-set content-library content-id
          {
            title: title,
            content-type: content-type,
            creator: creator,
            creation-date: current-time,
            premium: premium,
            total-plays: u0,
            total-minutes: u0
          }
        )
        
        ;; Update creator profile
        (if (is-some creator-info)
          (map-set content-creators creator
            (merge (unwrap-panic creator-info)
              {
                content-count: (+ (get content-count (unwrap-panic creator-info)) u1)
              }
            )
          )
          (map-set content-creators creator
            {
              registered: true,
              content-count: u1,
              total-plays: u0,
              total-minutes: u0,
              earned-stx: u0
            }
          )
        )
        
        ;; Increment content ID
        (var-set next-content-id (+ content-id u1))
        
        (ok content-id)
      )
    )
  )
)

;; Withdraw creator earnings
(define-public (withdraw-creator-earnings)
  (let
    (
      (creator tx-sender)
      (creator-info (map-get? content-creators creator))
    )
    (if (is-none creator-info)
      ERR-USER-NOT-FOUND
      (let
        (
          (creator-data (unwrap-panic creator-info))
          (earned-amount (get earned-stx creator-data))
        )
        (if (< earned-amount u1000000) ;; Minimum 1 STX withdrawal
          ERR-INSUFFICIENT-FUNDS
          (begin
            ;; Reset earned amount
            (map-set content-creators creator
              (merge creator-data
                {
                  earned-stx: u0
                }
              )
            )
            
            ;; Transfer STX to creator
            (as-contract (stx-transfer? earned-amount tx-sender creator))
          )
        )
      )
    )
  )
)

;; Change contract owner
(define-public (set-contract-owner (new-owner principal))
  (let
    (
      (current-owner (var-get contract-owner))
    )
    (if (is-eq tx-sender current-owner)
      (begin
        (var-set contract-owner new-owner)
        (ok true)
      )
      ERR-NOT-AUTHORIZED
    )
  )
)