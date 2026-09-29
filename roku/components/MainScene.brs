sub init()
    m.loginGroup = m.top.findNode("loginGroup")
    m.homeGroup = m.top.findNode("homeGroup")
    m.video = m.top.findNode("video")
    m.codeInput = m.top.findNode("codeInput")
    m.userInput = m.top.findNode("userInput")
    m.passInput = m.top.findNode("passInput")
    m.loginButton = m.top.findNode("loginButton")
    m.statusLabel = m.top.findNode("statusLabel")
    m.contentList = m.top.findNode("contentList")
    m.categoryList = m.top.findNode("categoryList")
    m.sectionTitle = m.top.findNode("sectionTitle")
    m.contentStatus = m.top.findNode("contentStatus")
    m.searchGroup = m.top.findNode("searchGroup")
    m.searchInput = m.top.findNode("searchInput")
    m.searchSubmitButton = m.top.findNode("searchSubmitButton")
    m.searchCancelButton = m.top.findNode("searchCancelButton")
    m.liveButton = m.top.findNode("liveButton")
    m.movieButton = m.top.findNode("movieButton")
    m.seriesButton = m.top.findNode("seriesButton")
    m.searchButton = m.top.findNode("searchButton")
    m.favoriteButton = m.top.findNode("favoriteButton")
    m.logoutButton = m.top.findNode("logoutButton")
    m.streams = []
    m.allItems = []
    m.visibleItems = []
    m.categories = []
    m.section = "live"
    m.pendingAction = ""
    m.favorites = {}
    m.dns = ""
    m.username = ""
    m.password = ""

    m.codeInput.observeField("text", "onFormChanged")
    m.userInput.observeField("text", "onFormChanged")
    m.passInput.observeField("text", "onFormChanged")
    m.loginButton.observeField("buttonSelected", "onLoginPressed")
    m.logoutButton.observeField("buttonSelected", "onLogoutPressed")
    m.contentList.observeField("itemSelected", "onContentSelected")
    m.categoryList.observeField("itemSelected", "onCategorySelected")
    m.liveButton.observeField("buttonSelected", "onLivePressed")
    m.movieButton.observeField("buttonSelected", "onMoviesPressed")
    m.seriesButton.observeField("buttonSelected", "onSeriesPressed")
    m.searchButton.observeField("buttonSelected", "onSearchPressed")
    m.favoriteButton.observeField("buttonSelected", "onFavoritesPressed")
    m.searchSubmitButton.observeField("buttonSelected", "onSearchSubmit")
    m.searchCancelButton.observeField("buttonSelected", "closeSearch")
    m.video.observeField("state", "onVideoState")

    loadFavorites()
    m.codeInput.setFocus(true)
    loadSavedLogin()
end sub

sub loadSavedLogin()
    section = CreateObject("roRegistrySection", "mplayer")
    m.codeInput.text = section.Read("partner_code")
    m.userInput.text = section.Read("username")
    m.passInput.text = section.Read("password")
end sub

sub saveLogin(code as string, user as string, password as string)
    section = CreateObject("roRegistrySection", "mplayer")
    section.Write("partner_code", code)
    section.Write("username", user)
    section.Write("password", password)
    section.Flush()
end sub

sub onFormChanged()
    ' keep observer attached
end sub

sub onLoginPressed()
    code = UCase(Trim(m.codeInput.text))
    user = Trim(m.userInput.text)
    password = Trim(m.passInput.text)
    if code = "" or user = "" or password = ""
        showStatus("Preencha código, usuário e senha.")
        return
    end if
    m.username = user
    m.password = password
    showStatus("Buscando DNS em mplayer.up.railway.app...")
    startGet("https://mplayer.up.railway.app/v1/partner-access/" + urlEncode(code), "partner")
end sub

sub startGet(url as string, kind as string)
    if m.activeTask <> invalid
        m.activeTask.unobserveField("done")
    end if
    task = createObject("roSGNode", "HttpTask")
    task.addField("kind", "string", false)
    task.kind = kind
    task.observeField("done", "onHttpDone")
    task.requestUrl = url
    m.activeTask = task
    task.control = "RUN"
end sub

sub onHttpDone()
    task = m.activeTask
    if task = invalid then return
    if task.errorMessage <> invalid and task.errorMessage <> "" and task.statusCode = 0
        showStatus(task.errorMessage)
        return
    end if
    if task.kind = "partner"
        handlePartner(task)
    else if task.kind = "xtream"
        handleXtream(task)
    else if task.kind = "movies"
        handleCatalog(task, "movies")
    else if task.kind = "series"
        handleCatalog(task, "series")
    else if task.kind = "series_info"
        handleSeriesInfo(task)
    end if
end sub

sub handlePartner(task as object)
    if task.statusCode <> 200
        showStatus("Código de parceiro não encontrado.")
        return
    end if
    data = ParseJson(task.body)
    if data = invalid or data.dns_url = invalid or data.dns_url = ""
        showStatus("A DNS deste parceiro ainda não foi configurada.")
        return
    end if
    m.dns = StripSlash(data.dns_url)
    showStatus("Conectando no Xtream...")
    api = m.dns + "/player_api.php?username=" + urlEncode(m.username) + "&password=" + urlEncode(m.password) + "&action=get_live_streams"
    startGet(api, "xtream")
end sub

sub handleXtream(task as object)
    if task.statusCode <> 200
        showStatus("Usuário ou senha Xtream inválidos.")
        return
    end if
    data = ParseJson(task.body)
    if GetInterface(data, "ifArray") = invalid
        showStatus("Não foi possível ler a lista de canais.")
        return
    end if
    if data.Count() = 0
        showStatus("Nenhum canal ao vivo encontrado.")
        return
    end if
    saveLogin(UCase(Trim(m.codeInput.text)), m.username, m.password)
    m.section = "live"
    m.allItems = normalizeItems(data, "live")
    m.streams = m.allItems
    m.loginGroup.visible = false
    m.homeGroup.visible = true
    m.video.visible = false
    renderCatalog("TV ao vivo")
    m.contentList.setFocus(true)
    showStatus("")
end sub

sub handleCatalog(task as object, section as string)
    if task.statusCode <> 200
        m.contentStatus.text = "Falha ao carregar conteúdo."
        return
    end if
    data = ParseJson(task.body)
    if GetInterface(data, "ifArray") = invalid
        m.contentStatus.text = "Resposta inválida do provedor."
        return
    end if
    m.section = section
    m.allItems = normalizeItems(data, section)
    title = "Filmes"
    if section = "series" then title = "Séries"
    renderCatalog(title)
    m.contentList.setFocus(true)
end sub

sub onContentSelected()
    index = m.contentList.itemSelected
    if index < 0 or index >= m.visibleItems.Count() then return
    item = m.visibleItems[index]
    if m.section = "series"
        seriesId = valueString(item, "series_id")
        if seriesId = "" then return
        m.pendingSeries = item
        m.contentStatus.text = "Carregando episódios..."
        startGet(apiUrl("get_series_info") + "&series_id=" + urlEncode(seriesId), "series_info")
        return
    end if
    playCatalogItem(item)
end sub

sub playCatalogItem(item as object)
    idKey = "stream_id"
    segment = "live"
    extension = "m3u8"
    format = "hls"
    if m.section = "movies" or item.Lookup("content_type") = "movies" or item.Lookup("content_type") = "movie"
        segment = "movie"
        extension = valueString(item, "container_extension")
        if extension = "" then extension = "mp4"
        format = extension
    else if item.Lookup("content_type") = "episode"
        segment = "series"
        extension = valueString(item, "container_extension")
        if extension = "" then extension = "mp4"
        format = extension
        idKey = "id"
    end if
    streamId = valueString(item, idKey)
    if streamId = "" then return
    url = m.dns + "/" + segment + "/" + urlEncode(m.username) + "/" + urlEncode(m.password) + "/" + streamId + "." + extension
    playUrl(url, valueString(item, "name"), format)
end sub

sub handleSeriesInfo(task as object)
    if task.statusCode <> 200
        m.contentStatus.text = "Não foi possível carregar os episódios."
        return
    end if
    data = ParseJson(task.body)
    if data = invalid or data.episodes = invalid
        m.contentStatus.text = "Nenhum episódio encontrado."
        return
    end if
    episodes = []
    for each seasonKey in data.episodes
        season = data.episodes[seasonKey]
        if GetInterface(season, "ifArray") <> invalid
            for each episode in season
                episode.AddReplace("content_type", "episode")
                if episode.name = invalid
                    episode.AddReplace("name", "T" + seasonKey + " E" + valueString(episode, "episode_num"))
                end if
                episodes.Push(episode)
            end for
        end if
    end for
    m.section = "episodes"
    m.allItems = episodes
    title = valueString(m.pendingSeries, "name")
    renderCatalog(title + " — episódios")
    m.contentList.setFocus(true)
end sub

sub onChannelSelected()
    index = m.contentList.itemSelected
    if index < 0 or index >= m.visibleItems.Count() then return
    item = m.visibleItems[index]
    streamId = item.stream_id
    if GetInterface(streamId, "ifString") = invalid
        streamId = streamId.ToStr()
    end if
    url = m.dns + "/live/" + urlEncode(m.username) + "/" + urlEncode(m.password) + "/" + streamId + ".m3u8"
    playUrl(url, item.name, "hls")
end sub

sub playUrl(url as string, title as string, streamFormat as string)
    content = CreateObject("roSGNode", "ContentNode")
    content.url = url
    content.title = title
    content.streamFormat = streamFormat
    m.video.content = content
    m.homeGroup.visible = false
    m.video.visible = true
    m.video.setFocus(true)
    m.video.control = "play"
end sub

sub onVideoState()
    state = m.video.state
    if state = "error"
        index = m.contentList.itemSelected
        if m.section = "live" and index >= 0 and index < m.visibleItems.Count()
            item = m.visibleItems[index]
            streamId = item.stream_id
            if GetInterface(streamId, "ifString") = invalid
                streamId = streamId.ToStr()
            end if
            tsUrl = m.dns + "/live/" + urlEncode(m.username) + "/" + urlEncode(m.password) + "/" + streamId + ".ts"
            if m.video.content <> invalid and Right(m.video.content.url, 5) = ".m3u8"
                playUrl(tsUrl, item.name, "ts")
                return
            end if
        end if
        stopPlayback()
        showStatus("Falha ao reproduzir este canal.")
    else if state = "finished"
        stopPlayback()
    end if
end sub

sub stopPlayback()
    m.video.control = "stop"
    m.video.visible = false
    m.homeGroup.visible = true
    m.contentList.setFocus(true)
end sub

sub onLivePressed()
    m.section = "live"
    m.allItems = m.streams
    renderCatalog("TV ao vivo")
end sub

sub onMoviesPressed()
    m.contentStatus.text = "Carregando filmes..."
    startGet(apiUrl("get_vod_streams"), "movies")
end sub

sub onSeriesPressed()
    m.contentStatus.text = "Carregando séries..."
    startGet(apiUrl("get_series"), "series")
end sub

sub onSearchPressed()
    m.searchGroup.visible = true
    m.searchInput.setFocus(true)
end sub

sub closeSearch()
    m.searchGroup.visible = false
    m.contentList.setFocus(true)
end sub

sub onSearchSubmit()
    query = LCase(Trim(m.searchInput.text))
    if query = ""
        m.searchStatus.text = "Digite o que deseja buscar."
        return
    end if
    results = []
    sources = [m.streams, m.allItems]
    for each source in sources
        for each item in source
            name = LCase(valueString(item, "name"))
            if Instr(1, name, query) > 0
                results.Push(item)
            end if
        end for
    end for
    m.allItems = uniqueItems(results)
    m.section = "search"
    closeSearch()
    renderCatalog("Resultados da busca")
end sub

sub onFavoritesPressed()
    results = []
    for each item in m.streams
        if m.favorites.DoesExist(itemKey(item, "live")) then results.Push(item)
    end for
    m.allItems = results
    m.section = "favorites"
    renderCatalog("Favoritos")
end sub

sub onCategorySelected()
    index = m.categoryList.itemSelected
    if index < 0 or index >= m.categories.Count() then return
    category = m.categories[index]
    applyCategory(category.id)
    m.contentList.setFocus(true)
end sub

sub renderCatalog(title as string)
    m.sectionTitle.text = title
    buildCategories()
    applyCategory("*")
    m.contentStatus.text = m.allItems.Count().ToStr() + " itens"
end sub

sub buildCategories()
    m.categories = []
    seen = {}
    m.categories.Push({ id: "*", name: "Todos" })
    for each item in m.allItems
        id = valueString(item, "category_id")
        if id = "" then id = "other"
        if not seen.DoesExist(id)
            seen[id] = true
            label = valueString(item, "category_name")
            if label = "" then label = "Categoria " + id
            m.categories.Push({ id: id, name: label })
        end if
    end for
    root = CreateObject("roSGNode", "ContentNode")
    for each category in m.categories
        node = root.CreateChild("ContentNode")
        node.title = category.name
    end for
    m.categoryList.content = root
end sub

sub applyCategory(categoryId as string)
    m.visibleItems = []
    root = CreateObject("roSGNode", "ContentNode")
    for each item in m.allItems
        if categoryId = "*" or valueString(item, "category_id") = categoryId or (categoryId = "other" and valueString(item, "category_id") = "")
            m.visibleItems.Push(item)
            node = root.CreateChild("ContentNode")
            prefix = ""
            if m.favorites.DoesExist(itemKey(item, m.section)) then prefix = "★ "
            node.title = prefix + valueString(item, "name")
        end if
    end for
    m.contentList.content = root
end sub

function normalizeItems(data as object, section as string) as object
    output = []
    maxItems = 1200
    for each item in data
        if output.Count() >= maxItems then exit for
        name = valueString(item, "name")
        if name = "" then name = valueString(item, "title")
        if name <> ""
            item.AddReplace("name", name)
            item.AddReplace("content_type", section)
            output.Push(item)
        end if
    end for
    return output
end function

function uniqueItems(items as object) as object
    result = []
    seen = {}
    for each item in items
        key = itemKey(item, valueString(item, "content_type"))
        if not seen.DoesExist(key)
            seen[key] = true
            result.Push(item)
        end if
    end for
    return result
end function

function apiUrl(action as string) as string
    return m.dns + "/player_api.php?username=" + urlEncode(m.username) + "&password=" + urlEncode(m.password) + "&action=" + action
end function

function valueString(item as dynamic, key as string) as string
    if item = invalid then return ""
    value = item.Lookup(key)
    if value = invalid then return ""
    if GetInterface(value, "ifString") <> invalid then return value
    return value.ToStr()
end function

function itemKey(item as object, section as string) as string
    id = valueString(item, "stream_id")
    if id = "" then id = valueString(item, "series_id")
    if id = "" then id = valueString(item, "id")
    return section + ":" + id
end function

sub loadFavorites()
    section = CreateObject("roRegistrySection", "mplayer_favorites")
    raw = section.Read("items")
    if raw <> invalid and raw <> ""
        parsed = ParseJson(raw)
        if parsed <> invalid then m.favorites = parsed
    end if
end sub

sub toggleFocusedFavorite()
    index = m.contentList.itemFocused
    if index < 0 or index >= m.visibleItems.Count() then return
    item = m.visibleItems[index]
    key = itemKey(item, m.section)
    if m.favorites.DoesExist(key)
        m.favorites.Delete(key)
    else
        m.favorites[key] = true
    end if
    section = CreateObject("roRegistrySection", "mplayer_favorites")
    section.Write("items", FormatJson(m.favorites))
    section.Flush()
    selectedCategory = "*"
    if m.categoryList.itemFocused >= 0 and m.categoryList.itemFocused < m.categories.Count()
        selectedCategory = m.categories[m.categoryList.itemFocused].id
    end if
    applyCategory(selectedCategory)
    m.contentList.setFocus(true)
end sub

sub onLogoutPressed()
    stopPlayback()
    m.homeGroup.visible = false
    m.loginGroup.visible = true
    m.loginButton.setFocus(true)
    showStatus("A DNS vem de mplayer.up.railway.app")
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back"
        if m.video.visible
            stopPlayback()
            return true
        else if m.searchGroup.visible
            closeSearch()
            return true
        else if m.homeGroup.visible
            m.liveButton.setFocus(true)
            return true
        end if
    else if key = "options"
        if m.homeGroup.visible and m.contentList.hasFocus()
            toggleFocusedFavorite()
            return true
        end if
    else if key = "right"
        if m.categoryList.hasFocus()
            m.contentList.setFocus(true)
            return true
        end if
    else if key = "left"
        if m.contentList.hasFocus()
            m.categoryList.setFocus(true)
            return true
        end if
    else if key = "down"
        if m.codeInput.hasFocus()
            m.userInput.setFocus(true)
            return true
        else if m.userInput.hasFocus()
            m.passInput.setFocus(true)
            return true
        else if m.passInput.hasFocus()
            m.loginButton.setFocus(true)
            return true
        else if m.liveButton.hasFocus() or m.movieButton.hasFocus() or m.seriesButton.hasFocus() or m.searchButton.hasFocus() or m.favoriteButton.hasFocus() or m.logoutButton.hasFocus()
            m.categoryList.setFocus(true)
            return true
        end if
    else if key = "up"
        if m.loginButton.hasFocus()
            m.passInput.setFocus(true)
            return true
        else if m.passInput.hasFocus()
            m.userInput.setFocus(true)
            return true
        else if m.userInput.hasFocus()
            m.codeInput.setFocus(true)
            return true
        else if m.categoryList.hasFocus() or m.contentList.hasFocus()
            m.liveButton.setFocus(true)
            return true
        end if
    end if
    return false
end function

sub showStatus(message as string)
    m.statusLabel.text = message
end sub

function Trim(value as dynamic) as string
    if value = invalid then return ""
    return value.Trim()
end function

function StripSlash(value as string) as string
    if Right(value, 1) = "/" then return Left(value, Len(value) - 1)
    return value
end function

function urlEncode(value as string) as string
    transfer = CreateObject("roUrlTransfer")
    return transfer.Escape(value)
end function
