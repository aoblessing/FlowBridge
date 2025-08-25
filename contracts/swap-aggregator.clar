;; title: swap-aggregator
;; version: 1.0.0
;; summary: FlowBridge DEX Aggregator for optimal STX/sBTC swaps
;; description: Aggregates liquidity from ALEX, Velar, and Bitflow for best swap rates

;; traits
(define-trait dex-interface
  (
    (get-quote (uint uint) (response {amount-out: uint, slippage: uint} uint))
    (execute-swap (uint uint principal) (response {amount-out: uint} uint))
  )
)

;; token definitions
(define-fungible-token sbtc)

;; constants
(define-constant ERR_INVALID_AMOUNT (err u100))
(define-constant ERR_NO_LIQUIDITY (err u101))
(define-constant ERR_SWAP_FAILED (err u102))
(define-constant ERR_SLIPPAGE_EXCEEDED (err u103))
(define-constant ERR_UNAUTHORIZED (err u104))

(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_SWAP_AMOUNT u1000)
(define-constant MAX_SLIPPAGE_BPS u1500) ;; 15% max slippage

;; data vars
(define-data-var total-swaps uint u0)
(define-data-var total-volume uint u0)

;; data maps
(define-map dex-addresses
  {dex: (string-ascii 20)}
  {contract: principal, active: bool}
)

(define-map swap-history
  {user: principal, swap-id: uint}
  {
    amount-in: uint,
    amount-out: uint,
    dex-used: (string-ascii 20),
    timestamp: uint,
    token-in: (string-ascii 10),
    token-out: (string-ascii 10)
  }
)

;; public functions
(define-public (register-dex (dex-name (string-ascii 20)) (dex-contract principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (map-set dex-addresses {dex: dex-name} {contract: dex-contract, active: true})
    (ok true)
  )
)

(define-public (get-best-quote (amount-in uint) (token-in (string-ascii 10)) (token-out (string-ascii 10)))
  (let
    (
      (alex-quote (get-dex-quote "ALEX" amount-in))
      (velar-quote (get-dex-quote "VELAR" amount-in))
      (bitflow-quote (get-dex-quote "BITFLOW" amount-in))
    )
    (ok (find-best-route alex-quote velar-quote bitflow-quote))
  )
)

(define-public (execute-aggregated-swap 
  (amount-in uint) 
  (min-amount-out uint)
  (token-in (string-ascii 10))
  (token-out (string-ascii 10))
  (dex-choice (string-ascii 20))
)
  (let
    (
      (swap-id (+ (var-get total-swaps) u1))
      (quote-result (unwrap! (get-dex-quote dex-choice amount-in) ERR_NO_LIQUIDITY))
    )
    (asserts! (>= amount-in MIN_SWAP_AMOUNT) ERR_INVALID_AMOUNT)
    (asserts! (>= (get amount-out quote-result) min-amount-out) ERR_SLIPPAGE_EXCEEDED)
    
    ;; Execute the swap (simplified - would call actual DEX contracts)
    (let ((swap-result (execute-swap-internal amount-in dex-choice)))
      (match swap-result
        success (begin
          (map-set swap-history 
            {user: tx-sender, swap-id: swap-id}
            {
              amount-in: amount-in,
              amount-out: (get amount-out success),
              dex-used: dex-choice,
              timestamp: stacks-block-height,
              token-in: token-in,
              token-out: token-out
            }
          )
          (var-set total-swaps swap-id)
          (var-set total-volume (+ (var-get total-volume) amount-in))
          (ok success)
        )
        error (err error)
      )
    )
  )
)

;; read only functions
(define-read-only (get-dex-quote (dex-name (string-ascii 20)) (amount-in uint))
  (let
    (
      (dex-info (map-get? dex-addresses {dex: dex-name}))
      (base-rate u95) ;; 95% rate simulation
      (slippage-factor (calculate-slippage amount-in))
    )
    (match dex-info
      dex-data (if (get active dex-data)
        (ok {
          amount-out: (/ (* amount-in base-rate slippage-factor) u10000),
          slippage: (- u100 slippage-factor),
          dex: dex-name
        })
        ERR_NO_LIQUIDITY
      )
      ERR_NO_LIQUIDITY
    )
  )
)

(define-read-only (get-swap-stats)
  (ok {
    total-swaps: (var-get total-swaps),
    total-volume: (var-get total-volume)
  })
)

(define-read-only (get-user-swap-history (user principal) (swap-id uint))
  (map-get? swap-history {user: user, swap-id: swap-id})
)

;; private functions
(define-private (find-best-route (alex-quote (response {amount-out: uint, slippage: uint, dex: (string-ascii 20)} uint))
                                (velar-quote (response {amount-out: uint, slippage: uint, dex: (string-ascii 20)} uint))
                                (bitflow-quote (response {amount-out: uint, slippage: uint, dex: (string-ascii 20)} uint)))
  (let
    (
      (alex-amount (match alex-quote 
        success (get amount-out success)
        error u0))
      (velar-amount (match velar-quote 
        success (get amount-out success)
        error u0))
      (bitflow-amount (match bitflow-quote 
        success (get amount-out success)
        error u0))
    )
    (if (and (> alex-amount velar-amount) (> alex-amount bitflow-amount))
      alex-quote
      (if (> velar-amount bitflow-amount)
        velar-quote
        bitflow-quote
      )
    )
  )
)

(define-private (calculate-slippage (amount uint))
  (if (< amount u10000)
    u98 ;; 2% slippage for small amounts
    (if (< amount u100000)
      u95 ;; 5% slippage for medium amounts
      u90 ;; 10% slippage for large amounts
    )
  )
)

(define-private (execute-swap-internal (amount-in uint) (dex-name (string-ascii 20)))
  (let
    (
      (quote (unwrap! (get-dex-quote dex-name amount-in) ERR_NO_LIQUIDITY))
      (amount-out (get amount-out quote))
    )
    ;; Simplified swap execution - in production would call actual DEX contracts
    (if (> amount-out u0)
      (ok {amount-out: amount-out})
      ERR_SWAP_FAILED
    )
  )
)

