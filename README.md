# Ticks

Solidity cannot support floating-point numbers. 0.1)

Ticks -> Represent token prices of a pair

Conceptually: a tick is the smallest amount possible by which the price of an asset can move up or down

## Getting a price using ticks

Formula for getting the price of a token is:

price(i) = 1.0001 ^ i
Where "i" = tick

If pool has tick = 0
price(i=0) = 1.0001 ^ 0 = 1

Token A <> Token B trade 1 <> 1
("Token A and Token B trade 1 to 1")

Price at tick 0 is equal to 1 because anything ^ 0 = 1

If the tick goes down to, let's say, -50

price(i = -50) = 1.0001 ^ (-50) = 0.9950127279

1 Token A = 0.9950127279 Token B

## Second example

If actual tick = 0.6 for example
Ticks are spaced at intervals of 1

We round the actual tick to either `tickLower` or `tickUpper` 0 and 1 respectively

# sqrtPriceLimitX96

Uniswap uses something called **Q Notation**

You can convert a number from it's Q Notation and viceversa following an equation

Let's say "V" is some value that is in decimal

V => Q Notation

To convert to Q notation:
V \* (2 ^ k) where k is some constant

To convert to Q notation with X96:
V \* (2 ^ 96)

Imagine V represented the price of Token A in terms of Token B

Let's say 1 token A = 1.000234 Token B

You can't store 1.000234 in Solidity, and if you have to round this, it'll round to 1, which would make the prices equal while they're not equal.

V \* (2 ^ 96) = 7.9246702e+28 = 79246702000000000000000000000 (uint160)

`swqrPriceX96` is the Q Notation value for the Square Root of the Price (right now)

To calculate the price: Price(i=currentTick) = 1.0001 ^ i

sqrtPriceX95 = (sqrt(Price)) \* (2^96)

`sqrtPriceLimitX96` specifies a LIMIT on the price ratio.

If token 1 is more expensive than token 0 - what does this imply?

1 Token0 = (<1) Token1
Note: <1 being "less than one"
