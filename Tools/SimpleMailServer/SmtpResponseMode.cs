namespace SimpleMailServer;

internal enum SmtpResponseMode
{
    Ok,
    TempFailure,
    NoSuchUser
}

internal enum SmtpMessageOutcome
{
    Ok,
    TempFailure,
    NoSuchUser,
    Silent
}
