# Sample project using CIG

This project demonstrates a basic project that uses CIG to sell NFTs.

It uses CIG both by accepting it as a token, and also uses the CEO to resolve any disputes (and issue refunds)

The Rules

1. Punk owner commissions the painter their punk painted (a job). A commission gets sent to escrow.
2. Painter finishes the painting, and uploads the image, sets the URL, marking the job
   "Complete" and available to be accepted by the commissioner.
3. Commissioner accepts the job, receives the NFT, commission is released from escrow and sent to painter
4. Dispute: If not accepted in step 3, the CEO would need to resolve the dispute.
   The CEO will either accept the job, or refund the job. CEO will receive a 10% fee deducted from the escrow.
5. Up to 20 jobs can be opened at the same time

### This is a work-in-progress and so far for demo purposes. Not used in production and lacks any testing.