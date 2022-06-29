################################ FUNCOES AUXILIARES PARA OS SCRIPTS ################################

#' Identifica Quadrante Da Usina
#' 
#' Identifica entre quais vertices de \code{coords} esta \code{usina}
#' 
#' \code{usinas} deve corresponder a uma ou mais linhas do dado na tabela \code{usinas} do banco ou 
#' arquivo "Dados das Usinas.txt", com colunas renomeadas para o mesmo padrao do dado no banco. No
#' minimo, code{usinas} deve ter duas colinas indicando longitude e latitude, com estes nomes. O 
#' restante das colunas nao tem uso nessa funcao.
#' 
#' \code{coords} deve ter tres colunas nomeadas: \code{longitude} e \code{latitude} contendo as 
#' coordenadas do vertice e \code{ind} contendo o indice do vertice, um valor inteiro nao repetido.
#' 
#' @param usinas \code{data.table} contendo informacoes das usinas. Ver Detalhes
#' @param coords \code{data.table} contendo informacoes dos vertices da grade. Ver Detalhes
#' 
#' @return vetor de indices dos vertices do quadrilatero circulante, em sentido anti-horario a 
#'     partir do vertice superior direito. Se alguma usina nao estiver dentro da grade, volta NA

quadrante_usina <- function(usinas, coords) {

    usinas <- as.data.table(usinas)

    lons <- sort(unique(coords$longitude))
    lats <- sort(unique(coords$latitude))

    out <- lapply(seq(nrow(usinas)), function(i) {
        tryCatch({
        lonusi <- usinas$longitude[i]
        latusi <- usinas$latitude[i]

        lon_p <- head(lons[lons >= lonusi], 1)
        lon_m <- tail(lons[lons <= lonusi], 1)
        lat_p <- head(lats[lats >= latusi], 1)
        lat_m <- tail(lats[lats <= latusi], 1)

        verts <- vector("double", 4L)
        verts[1] <- coords[(longitude == lon_p) & (latitude == lat_p), ind]
        verts[2] <- coords[(longitude == lon_m) & (latitude == lat_p), ind]
        verts[3] <- coords[(longitude == lon_m) & (latitude == lat_m), ind]
        verts[4] <- coords[(longitude == lon_p) & (latitude == lat_m), ind]

        return(verts)
        }, error = function(e) rep(NA_real_, 4))
    })

    return(out)
}

#' Interpolacao Bilinear Na Grade
#' 
#' Interpola a serie de vento de reanalise numa coordenada qualquer dentro da grade
#' 
#' Considerando o tamanho do dado de reanalise, e mais eficiente que \code{interp_usina} receba a 
#' conexao ao banco do que exigir que o usuario mantenha todo o \code{data.table} em memoria e o 
#' passe para a funcao (correndo ainda o risco de realizar copias disso). As usinas a serem 
#' interpoladas sao reordenadas de modo a minimizar o numero de queries.
#' 
#' \code{usinas} deve corresponder a uma ou mais linhas do dado na tabela \code{usinas} do banco ou 
#' arquivo "Dados das Usinas.txt", com colunas renomeadas para o mesmo padrao do dado no banco. No
#' minimo, code{usinas} deve ter duas colinas indicando longitude e latitude, com estes nomes, e uma
#' coluna chamada codigo contendo o codigo de seis caracters da usina. O restante das colunas nao
#' tem uso nessa funcao.
#' 
#' \code{coords} deve ter tres colunas nomeadas: \code{longitude} e \code{latitude} contendo as 
#' coordenadas do vertice e \code{ind} contendo o indice do vertice, um valor inteiro nao repetido.
#' 
#' @param usinas \code{data.table} contendo informacoes das usinas. Ver Detalhes
#' @param coords \code{data.table} contendo informacoes dos vertices da grade. Ver Detalhes
#' @param conn conexao ao banco contendo o dado de reanalise
#' 
#' @return \code{data.table} de tres colunas: \code{data_hora}, \code{vento_reanalise} e 
#'     \code{codigo}. O dado nao estara ordenado conforme as ordem em \code{usinas} e possivelmente
#'     nao contera todas as usinas, caso alguma esteja fora da grade de reanalise

interp_usina <- function(usinas, coords, conn, datas = "2017/") {

    usinas <- as.data.table(usinas)

    datas <- dbrenovaveis:::parsedatas(datas, "", FALSE)
    anos  <- c(year(datas[[1]][1]), year(datas[[2]][2]))

    quads <- quadrante_usina(usinas, coords)
    quads <- as.data.table(do.call(rbind, quads))
    quads <- quads[, c(3, 2, 4, 1)] # reorndena para uma estrutura adaptada pra interp bilin
    colnames(quads) <- paste0("vert", seq_len(4))

    usinas_vert <- cbind(usinas, quads)
    setorder(usinas_vert, vert1, na.last = TRUE)

    quad11 <- 0

    interps <- lapply(seq(nrow(usinas_vert)), function(i) {

        verts <- usinas_vert[i, c(vert1, vert2, vert3, vert4)]
        if(is.na(verts[1])) return(NULL)

        coords_quad <- coords[verts, ]

        if(verts[1] != quad11) {
            quad11 <- verts[1]

            deltax <- diff(sort(unique(coords_quad$longitude)))
            deltay <- diff(sort(unique(coords_quad$latitude)))

            queries <- paste0("SELECT vr_velocidade FROM FT_MERRA2",
                " WHERE id_lon = ", coords_quad$longitude, " AND id_lat = ", coords_quad$latitude,
                " AND id_ano >= ", anos[1], " AND id_ano <= ", anos[2]
                )
            series <- lapply(seq(queries), function(i) unlist(dbGetQuery(conn, queries[i])))
        }

        deltax1 <- usinas_vert[i, longitude] - min(coords_quad$longitude)
        deltax2 <- max(coords_quad$longitude) - usinas_vert[i, longitude]
        deltay1 <- usinas_vert[i, latitude] - min(coords_quad$latitude)
        deltay2 <- max(coords_quad$latitude) - usinas_vert[i, latitude]

        pesos <- 1 / (deltax * deltay) * c(deltax2 * deltay2, deltax1 * deltay2,
            deltax2 * deltay1, deltax1 * deltay1)

        vec <- rowSums(mapply("*", series, pesos))
        unname(vec)
    })
    interps <- interps[!sapply(interps, is.null)]

    datas <- dbGetQuery(conn, paste0("SELECT id_ano,id_mes,id_dia,id_hora FROM FT_MERRA2",
        " WHERE id_lon = ", coords$longitude[1], " AND id_lat = ", coords$latitude[1],
        " AND id_ano >= ", anos[1], " AND id_ano <= ", anos[2]))
    datas <- as.data.table(datas)
    datas[, c("id_mes", "id_dia", "id_hora") := lapply(.SD, formatC, width = 2, flag = "0"),
        .SDcols = c("id_mes", "id_dia", "id_hora")]
    datas <- datas[, paste0(paste(id_ano, id_mes, id_dia, sep = "-"), " ", id_hora, ":00:00")]
    datas <- as.POSIXct(datas, "GMT")

    interps <- lapply(interps, function(v) data.table(data_hora = datas, vento_reanalise = v))
    interps <- lapply(seq(interps), function(i) cbind(interps[[i]], codigo = usinas_vert$codigo[i]))
    interps <- rbindlist(interps)

    return(interps)
}