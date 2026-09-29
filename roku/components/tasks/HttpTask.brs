sub init()
    m.top.functionName = "exec"
end sub

sub exec()
    url = m.top.requestUrl
    m.top.statusCode = 0
    m.top.body = ""
    m.top.errorMessage = ""
    m.top.done = false
    if url = invalid or url = ""
        m.top.errorMessage = "URL vazia"
        m.top.done = true
        return
    end if

    transfer = CreateObject("roUrlTransfer")
    port = CreateObject("roMessagePort")
    transfer.SetMessagePort(port)
    transfer.SetUrl(url)
    transfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.InitClientCertificates()
    transfer.EnablePeerVerification(true)
    transfer.EnableHostVerification(true)
    transfer.AddHeader("User-Agent", "Mplayer/1.0 (Roku)")
    transfer.AddHeader("Accept", "application/json")
    transfer.SetRequest("GET")
    if transfer.AsyncGetToString()
        msg = wait(20000, port)
        if type(msg) = "roUrlEvent"
            m.top.statusCode = msg.GetResponseCode()
            m.top.body = msg.GetString()
            if m.top.statusCode < 200 or m.top.statusCode >= 300
                m.top.errorMessage = "HTTP " + m.top.statusCode.ToStr()
            end if
        else
            m.top.errorMessage = "Tempo esgotado ao falar com o servidor"
        end if
    else
        m.top.errorMessage = "Falha ao iniciar o pedido"
    end if
    m.top.done = true
end sub
