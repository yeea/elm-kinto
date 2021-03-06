module Kinto exposing
    ( Client, client, Auth(..), headersForAuth, Resource, bucketResource, collectionResource, recordResource, decodeData, encodeData, errorDecoder, errorToString
    , Request
    , get, create, update, replace, delete
    , getList
    , Pager, emptyPager, updatePager, loadNextPage
    , sort, limit, filter, Filter(..)
    , Endpoint(..), endpointUrl, ErrorDetail, Error(..)
    , send
    , expectJson, withQueryParam
    )

{-| [Kinto](http://www.kinto-storage.org/) client to ease communicating with
the REST API.

Kinto is the backend for your next application. It's a generic JSON document
store with sharing and synchronisation capabilities. It's open source. It's
easy to deploy. You can host it yourself, own your data and keep it out of
silos.


# Configure a client and resources

@docs Client, client, Auth, headersForAuth, Resource, bucketResource, collectionResource, recordResource, decodeData, encodeData, errorDecoder, errorToString


# Creating requests

You create requests on either an item or a plural (list) endpoint.
[Kinto concepts](http://kinto.readthedocs.io/en/stable/concepts.html) explain
that in details.

Plural (list) endpoints are:

  - buckets: `buckets/`
  - collections: `buckets/:bucketId/collections/`
  - records: `buckets/:bucketId/collections/:collectionId/records/`

Item endpoints are:

  - bucket: `buckets/:bucketId`
  - collection: `buckets/:bucketId/collections/:collectionId`
  - record: `buckets/:bucketId/collections/:collectionId/records/:recordId`

@docs Request


## Single item requests

@docs get, create, update, replace, delete


## Resource list requests

@docs getList


### Paginated list

@docs Pager, emptyPager, updatePager, loadNextPage


# Sorting, limiting, filtering

@docs sort, limit, filter, Filter


# Types and Errors

@docs Endpoint, endpointUrl, ErrorDetail, Error, extractError


# Sending requests

@docs send, toRequest

-}

import Base64
import Dict
import Http
import HttpBuilder
import Json.Decode as Decode
import Json.Encode as Encode
import Url.Builder exposing (string, toQuery)


type alias Url =
    String


{-| A type describing a Kinto request. Basically an alias for an
[elm-http-builder](https://package.elm-lang.org/packages/lukewestby/elm-http-builder/latest)
request builder.
-}
type alias Request a =
    HttpBuilder.RequestBuilder a



-- Auth


{-| A type for authentication

    Basic "username" "password"

    Bearer "<token>"

    Custom "customType" "customString"

-}
type Auth
    = NoAuth
    | Basic String String
    | Bearer String
    | Custom String String



-- Kinto types


type alias BucketName =
    String


type alias CollectionName =
    String


type alias RecordId =
    String


{-| A type for Kinto API endpoints.

    RecordEndpoint "bucket-name" "collection-name" "item-id"

-}
type Endpoint
    = RootEndpoint
    | BucketListEndpoint
    | BucketEndpoint BucketName
    | CollectionListEndpoint BucketName
    | CollectionEndpoint BucketName CollectionName
    | RecordListEndpoint BucketName CollectionName
    | RecordEndpoint BucketName CollectionName RecordId


{-| A type for filtering, used with `filter`
-}
type Filter
    = EQUAL String String
    | MIN String String
    | MAX String String
    | LT String String
    | GT String String
    | IN String (List String)
    | NOT String String
    | LIKE String String
    | SINCE String
    | BEFORE String


type alias Body =
    Encode.Value


{-| A Kinto Client. Constructed using the `client` helper.
-}
type alias Client =
    { baseUrl : String
    , headers : List ( String, String )
    }


{-| A type for a Kinto resource. Usually constructed using one of `bucketResource`,
`collectionResource` or `recordResource`.
-}
type alias Resource a =
    { itemEndpoint : String -> Endpoint
    , listEndpoint : Endpoint
    , itemDecoder : Decode.Decoder a
    , listDecoder : Decode.Decoder (List a)
    }


{-| A constructor for a bucket resource.

    bucketResource bucketDecoder

-}
bucketResource : Decode.Decoder a -> Resource a
bucketResource decoder =
    Resource
        BucketEndpoint
        BucketListEndpoint
        (decodeData decoder)
        (decodeData (Decode.list decoder))


{-| A constructor for a collection resource.

    collectionResource "bucket-name" collectionDecoder

-}
collectionResource : BucketName -> Decode.Decoder a -> Resource a
collectionResource bucket decoder =
    Resource
        (CollectionEndpoint bucket)
        (CollectionListEndpoint bucket)
        (decodeData decoder)
        (decodeData (Decode.list decoder))


{-| A constructor for a record resource.
-}
recordResource : BucketName -> CollectionName -> Decode.Decoder a -> Resource a
recordResource bucket collection decoder =
    Resource
        (RecordEndpoint bucket collection)
        (RecordListEndpoint bucket collection)
        (decodeData decoder)
        (decodeData (Decode.list decoder))


{-| A decoder for a basic Kinto response.
-}
decodeData : Decode.Decoder a -> Decode.Decoder a
decodeData decoder =
    Decode.field "data" decoder


{-| An encoder for a basic Kinto query.
-}
encodeData : Encode.Value -> Encode.Value
encodeData encoder =
    Encode.object
        [ ( "data", encoder ) ]



-- Pagination


{-| A stateful accumulator for a paginated list of objects.
-}
type alias Pager a =
    { client : Client
    , objects : List a
    , decoder : Decode.Decoder (List a)
    , total : Int
    , nextPage : Maybe Url
    }


{-| Initialize a `Pager`.

    emptyPager resource

-}
emptyPager : Client -> Resource a -> Pager a
emptyPager clientInstance resource =
    { client = clientInstance
    , objects = []
    , decoder = resource.listDecoder
    , total = 0
    , nextPage = Nothing
    }


{-| Update a previous pager with data from a new one, appending new objects
to the previous list.

    updatePager nextPager previousPager

-}
updatePager : Pager a -> Pager a -> Pager a
updatePager nextPager previousPager =
    { previousPager
        | total = nextPager.total
        , nextPage = nextPager.nextPage
        , objects = previousPager.objects ++ nextPager.objects
    }



-- Kinto errors


{-| A type for Kinto error details.
-}
type alias ErrorDetail =
    { errno : Int
    , message : String
    , code : Int
    , error : String
    }


type alias StatusCode =
    Int


type alias StatusMsg =
    String


{-| A type for all errors that the elm-client may return.
-}
type Error
    = ServerError StatusCode StatusMsg String
    | KintoError StatusCode StatusMsg ErrorDetail
    | NetworkError (Http.Response String)


{-| Convert any Kinto.Error to a string
-}
errorToString : Error -> String
errorToString error =
    case error of
        ServerError status message info ->
            String.fromInt status ++ " " ++ message ++ " " ++ info

        KintoError status message detail ->
            String.fromInt status ++ " " ++ message ++ " " ++ detail.message

        NetworkError _ ->
            "NetworkError"



-- Making requests


{-| Get the full url to an endpoint.

    endpointUrl "https://kinto.dev.mozaws.net/v1/" (RecordListEndpoint "default" "test-items")

-}
endpointUrl : String -> Endpoint -> Url
endpointUrl baseUrl endpoint =
    let
        url =
            if String.endsWith "/" baseUrl then
                String.dropRight 1 baseUrl

            else
                baseUrl

        joinUrl =
            String.join "/"
    in
    case endpoint of
        RootEndpoint ->
            -- Otherwise Kinto returns a 307
            -- See https://github.com/Kinto/kinto/issues/852
            url ++ "/"

        BucketListEndpoint ->
            joinUrl [ url, "buckets" ]

        BucketEndpoint bucketName ->
            joinUrl [ url, "buckets", bucketName ]

        CollectionListEndpoint bucketName ->
            joinUrl [ url, "buckets", bucketName, "collections" ]

        CollectionEndpoint bucketName collectionName ->
            joinUrl [ url, "buckets", bucketName, "collections", collectionName ]

        RecordListEndpoint bucketName collectionName ->
            joinUrl [ url, "buckets", bucketName, "collections", collectionName, "records" ]

        RecordEndpoint bucketName collectionName recordId ->
            joinUrl [ url, "buckets", bucketName, "collections", collectionName, "records", recordId ]


alwaysEncode : String -> String
alwaysEncode string =
    Base64.encode string



-- Dealing with answers from the Kinto server


{-| A decoder for `ErrorDetail`. This is the kind of json message answered by Kinto when there's an error:

    {"errno":104,
     "message":"Please authenticate yourself to use this endpoint.",
     "code":401,
     "error":"Unauthorized"}

-}
errorDecoder : Decode.Decoder ErrorDetail
errorDecoder =
    Decode.map4 ErrorDetail
        (Decode.field "errno" Decode.int)
        (Decode.field "message" Decode.string)
        (Decode.field "code" Decode.int)
        (Decode.field "error" Decode.string)


{-| Extract an `Error` from an `Http.Error` or return the decoded value.
-}
expectJson : (Result Error a -> msg) -> Decode.Decoder a -> Http.Expect msg
expectJson toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadStatus_ { statusCode, statusText } body ->
                    Err <| extractKintoError statusCode statusText body

                Http.GoodStatus_ { statusCode, statusText } body ->
                    case Decode.decodeString decoder body of
                        Ok value ->
                            Ok value

                        Err err ->
                            Err
                                (ServerError
                                    statusCode
                                    statusText
                                    ("failed decoding json: "
                                        ++ Decode.errorToString err
                                        ++ "\n\nBody received from server: "
                                        ++ body
                                    )
                                )

                anyError ->
                    NetworkError anyError |> Err


expectPagerJson : (Result Error (Pager a) -> msg) -> Client -> Decode.Decoder (List a) -> Http.Expect msg
expectPagerJson toMsg clientInstance decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadStatus_ { statusCode, statusText } body ->
                    Err <| extractKintoError statusCode statusText body

                Http.GoodStatus_ { headers, statusCode, statusText } body ->
                    let
                        nextPage =
                            Dict.get "next-page" headers

                        total =
                            Dict.get "total-records" headers
                                |> Maybe.map (String.toInt >> Maybe.withDefault 0)
                                |> Maybe.withDefault 0

                        createPager objects =
                            { client = clientInstance
                            , objects = objects
                            , decoder = decoder
                            , total = total
                            , nextPage = nextPage
                            }
                    in
                    case Decode.decodeString decoder body of
                        Ok value ->
                            Ok <| createPager value

                        Err err ->
                            Err
                                (ServerError
                                    statusCode
                                    statusText
                                    ("failed decoding json: "
                                        ++ Decode.errorToString err
                                        ++ "\n\nBody received from server: "
                                        ++ body
                                    )
                                )

                anyError ->
                    NetworkError anyError |> Err


extractKintoError : StatusCode -> StatusMsg -> String -> Error
extractKintoError statusCode statusMsg body =
    case Decode.decodeString errorDecoder body of
        Ok errRecord ->
            KintoError statusCode statusMsg errRecord

        Err err ->
            Decode.errorToString err
                |> ServerError statusCode statusMsg


withQueryParam : ( String, String ) -> Request a -> Request a
withQueryParam ( paramKey, paramValue ) builder =
    let
        ( url, params ) =
            case String.split "?" builder.url of
                [ path, qs ] ->
                    ( path
                    , qs
                        |> String.split "&"
                        |> List.filterMap (tupleSplit "=")
                        |> List.map (\( key, value ) -> string key value)
                    )

                [ path ] ->
                    ( path, [] )

                _ ->
                    ( "", [] )

        queryString =
            params
                |> List.append [ string paramKey paramValue ]
                |> toQuery
                |> String.replace "%20" "+"
    in
    { builder | url = url ++ queryString }


tupleSplit : String -> String -> Maybe ( String, String )
tupleSplit sep string =
    case String.split sep string of
        [ key, value ] ->
            Just ( key, value )

        _ ->
            Nothing



-- Helpers


{-| Return the header name and value for the given `Auth`.

    headersForAuth (Basic "username" "password")

-}
headersForAuth : Auth -> ( String, String )
headersForAuth auth =
    case auth of
        NoAuth ->
            ( "Authorization", "" )

        Basic username password ->
            ( "Authorization"
            , "Basic " ++ alwaysEncode (username ++ ":" ++ password)
            )

        Bearer token ->
            ( "Authorization", "Bearer " ++ token )

        Custom realm token ->
            ( "Authorization", realm ++ " " ++ token )


{-| A constructor for a `Client`.

    client
        "https://kinto.dev.mozaws.net/v1/"
        (Basic "username" "password")

-}
client : Url -> Auth -> Client
client baseUrl auth =
    Client baseUrl [ headersForAuth auth ]



-- Filtering


{-| Add [filtering query parameters](http://kinto.readthedocs.io/en/stable/api/1.x/filtering.html) to the request sent to the Kinto server.

    type Msg = TodosFetched (Result Kinto.Error (Kinto.pager Todo))

    client
        |> getList recordResource
        |> filter (NOT "title" "test")
        |> send TodosFetched

-}
filter : Filter -> Request a -> Request a
filter filterValue builder =
    let
        param =
            case filterValue of
                EQUAL key val ->
                    ( key, val )

                MIN key val ->
                    ( "min_" ++ key, val )

                MAX key val ->
                    ( "max_" ++ key, val )

                LT key val ->
                    ( "lt_" ++ key, val )

                GT key val ->
                    ( "gt_" ++ key, val )

                IN key values ->
                    ( "in_" ++ key, String.join "," values )

                NOT key val ->
                    ( "not_" ++ key, val )

                LIKE key val ->
                    ( "like_" ++ key, val )

                SINCE val ->
                    ( "_since", val )

                BEFORE val ->
                    ( "_before", val )
    in
    builder
        |> withQueryParam param



-- Sorting


{-| Add [sorting query parameters](http://kinto.readthedocs.io/en/stable/api/1.x/sorting.html) to the request sent to the Kinto server.

    type Msg = TodosFetched (Result Kinto.Error (Kinto.pager Todo))

    client
        |> getList recordResource
        |> sort ["title", "description"]
        |> send TodosFetched

-}
sort :
    List String
    -> Request a
    -> Request a
sort keys builder =
    builder
        |> withQueryParam ( "_sort", String.join "," keys )



-- Limiting


{-| Add [limit query parameters](http://kinto.readthedocs.io/en/stable/api/1.x/pagination.html) to the request sent to the Kinto server.

    type Msg = TodosFetched (Result Kinto.Error (Kinto.pager Todo))

    client
        |> getList recordResource
        |> limit 10
        |> send TodosFetched

-}
limit :
    Int
    -> Request a
    -> Request a
limit perPage builder =
    builder
        |> withQueryParam ( "_limit", String.fromInt perPage )



-- High level API


{-| Send a request to the Kinto server.

    type Msg = TodoAdded (Result Kinto.Error Todo)

    client
        |> create resource data
        |> send TodoAdded

-}
send : Request a -> Cmd a
send =
    HttpBuilder.request


{-| Create a GET request on an item endpoint

    client
        |> get resource itemId

-}
get : Resource a -> String -> (Result Error a -> msg) -> Client -> Request msg
get resource itemId toMsg clientInstance =
    endpointUrl clientInstance.baseUrl (resource.itemEndpoint itemId)
        |> HttpBuilder.get
        |> HttpBuilder.withHeaders clientInstance.headers
        |> HttpBuilder.withExpect (expectJson toMsg resource.itemDecoder)


{-| Create a GET request on one of the plural endpoints. As lists are always
possibly paginated, When the request is succesful, a `Pager` is attached to the
reponse message.

    client
        |> getList resource

-}
getList : Resource a -> (Result Error (Pager a) -> msg) -> Client -> Request msg
getList resource toMsg clientInstance =
    endpointUrl clientInstance.baseUrl resource.listEndpoint
        |> HttpBuilder.get
        |> HttpBuilder.withHeaders clientInstance.headers
        |> HttpBuilder.withExpect
            (expectPagerJson toMsg clientInstance resource.listDecoder)


{-| If a pager has a `nextPage`, creates a GET request to retrieve the next page of objects.
When the request is succesful, a `Pager` with new objects appended is attached to the
reponse message.

    client
        |> loadNextPage pager

-}
loadNextPage : Pager a -> (Result Error (Pager a) -> msg) -> Maybe (Request msg)
loadNextPage pager toMsg =
    pager.nextPage
        |> Maybe.andThen
            (\nextPage ->
                nextPage
                    |> HttpBuilder.get
                    |> HttpBuilder.withHeaders pager.client.headers
                    |> HttpBuilder.withExpect
                        (expectPagerJson toMsg pager.client pager.decoder)
                    |> Just
            )


{-| Create a DELETE request on an item endpoint:

    client
        |> delete resource itemId

-}
delete : Resource a -> String -> (Result Error a -> msg) -> Client -> Request msg
delete resource itemId toMsg clientInstance =
    endpointUrl clientInstance.baseUrl (resource.itemEndpoint itemId)
        |> HttpBuilder.delete
        |> HttpBuilder.withHeaders clientInstance.headers
        |> HttpBuilder.withExpect (expectJson toMsg resource.itemDecoder)


{-| Create a POST request on a plural endpoint:

    client
        |> create resource itemId data

-}
create : Resource a -> Body -> (Result Error a -> msg) -> Client -> Request msg
create resource body toMsg clientInstance =
    endpointUrl clientInstance.baseUrl resource.listEndpoint
        |> HttpBuilder.post
        |> HttpBuilder.withHeaders clientInstance.headers
        |> HttpBuilder.withJsonBody (encodeData body)
        |> HttpBuilder.withExpect (expectJson toMsg resource.itemDecoder)


{-| Create a PATCH request on an item endpoint:

    client
        |> update resource itemId data

-}
update : Resource a -> String -> Body -> (Result Error a -> msg) -> Client -> Request msg
update resource itemId body toMsg clientInstance =
    endpointUrl clientInstance.baseUrl (resource.itemEndpoint itemId)
        |> HttpBuilder.patch
        |> HttpBuilder.withHeaders clientInstance.headers
        |> HttpBuilder.withJsonBody (encodeData body)
        |> HttpBuilder.withExpect (expectJson toMsg resource.itemDecoder)


{-| Create a PUT request on an item endpoint:

    client
        |> replace resource itemId data

-}
replace : Resource a -> String -> Body -> (Result Error a -> msg) -> Client -> Request msg
replace resource itemId body toMsg clientInstance =
    endpointUrl clientInstance.baseUrl (resource.itemEndpoint itemId)
        |> HttpBuilder.put
        |> HttpBuilder.withHeaders clientInstance.headers
        |> HttpBuilder.withJsonBody (encodeData body)
        |> HttpBuilder.withExpect (expectJson toMsg resource.itemDecoder)
