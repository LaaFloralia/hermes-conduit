# Composer: iPhone checks

The simulator cannot run Simeji. These checks remain open until performed on
an iPhone with the LAA build. Use a test conversation where sending is safe.

1. In both the regular composer and full editor, use the Japanese iOS keyboard
   and Simeji to type kana, choose and revise predictive candidates, move the
   cursor, edit inside a conversion, and enter multiple lines. Check that text,
   candidates, and selection do not jump or disappear while responses stream.
2. Change the input and response sizes separately in Settings > Chat. Check
   both fields and message bubbles, including a long draft and the full editor.
3. Leave different drafts in two conversations, force-quit the app from the
   app switcher, reopen it, and check that each draft and attachment returns
   to its own conversation.
4. In a test conversation, interrupt the connection or force-quit while a send
   is awaiting its result. Reopen and check for the delivery-unknown notice;
   verify the conversation before confirming delivery or restoring the draft.
   Confirm there was no automatic resend and that words typed after the send
   remain separate. Repeat for a waiting send and a group room.
5. For a group-room unknown send, use its explicit retry and confirm the
   conversation contains one message, including when the first attempt landed.

The automated marked-text regression tests cover deferred replacement, cursor
and selection preservation, and deferred font changes in both UIKit bridges;
they do not prove Simeji's on-device behavior.
