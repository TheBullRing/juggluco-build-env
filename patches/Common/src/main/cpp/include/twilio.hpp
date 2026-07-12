// twilio.hpp
// Twilio credentials for dynamic TURN server tokens.
// Fill these in with your own Twilio Account SID and base64(SID:AuthToken).
// If left as empty strings the app still works — it just won't refresh TURN
// credentials from Twilio and will fall back to the static servers in turnservers.hpp.
#define TWILIOACCOUNT   ""
#define USERPASSBASE64  ""
