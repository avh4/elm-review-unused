module NoUnused.Patterns exposing (rule)

{-|

@docs rule

-}

import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern)
import Elm.Syntax.Range exposing (Range)
import NoUnused.Patterns.NameVisitor as NameVisitor
import Review.Fix as Fix
import Review.Rule as Rule exposing (Rule)
import Set exposing (Set)


{-| Forbid unused patterns.

    config : List Rule
    config =
        [ NoUnused.Patterns.rule
        ]

-}
rule : Rule
rule =
    Rule.newModuleRuleSchema "NoUnused.Patterns" initialContext
        |> Rule.withDeclarationVisitor declarationVisitor
        |> Rule.withExpressionVisitor expressionVisitor
        |> NameVisitor.withValueVisitor valueVisitor
        |> Rule.fromModuleRuleSchema


declarationVisitor : Node Declaration -> Rule.Direction -> Context -> ( List (Rule.Error {}), Context )
declarationVisitor node direction context =
    case ( direction, Node.value node ) of
        ( Rule.OnEnter, Declaration.FunctionDeclaration { declaration } ) ->
            ( [], rememberFunctionImplementation declaration context )

        ( Rule.OnExit, Declaration.FunctionDeclaration { declaration } ) ->
            errorsForFunctionImplementation declaration context

        _ ->
            ( [], context )


expressionVisitor : Node Expression -> Rule.Direction -> Context -> ( List (Rule.Error {}), Context )
expressionVisitor (Node _ expression) direction context =
    case ( direction, expression ) of
        ( Rule.OnEnter, Expression.LambdaExpression { args } ) ->
            ( [], rememberPatternList args context )

        ( Rule.OnExit, Expression.LambdaExpression { args } ) ->
            errorsForPatternList args context

        ( Rule.OnEnter, Expression.LetExpression { declarations } ) ->
            ( [], rememberLetDeclarationList declarations context )

        ( Rule.OnExit, Expression.LetExpression { declarations } ) ->
            errorsForLetDeclarationList declarations context

        ( Rule.OnEnter, Expression.CaseExpression { cases } ) ->
            ( [], rememberCaseList cases context )

        ( Rule.OnExit, Expression.CaseExpression { cases } ) ->
            errorsForCaseList cases context

        _ ->
            ( [], context )


valueVisitor : Node ( ModuleName, String ) -> Context -> ( List (Rule.Error {}), Context )
valueVisitor (Node _ ( moduleName, value )) context =
    case moduleName of
        [] ->
            ( [], useValue value context )

        _ ->
            ( [], context )



--- ON ENTER


rememberCaseList : List Expression.Case -> Context -> Context
rememberCaseList list context =
    List.foldl rememberCase context list


rememberCase : Expression.Case -> Context -> Context
rememberCase ( pattern, _ ) context =
    rememberPattern pattern context


rememberFunctionImplementation : Node Expression.FunctionImplementation -> Context -> Context
rememberFunctionImplementation (Node _ { arguments }) context =
    rememberPatternList arguments context


rememberLetDeclarationList : List (Node Expression.LetDeclaration) -> Context -> Context
rememberLetDeclarationList list context =
    List.foldl rememberLetDeclaration context list


rememberLetDeclaration : Node Expression.LetDeclaration -> Context -> Context
rememberLetDeclaration (Node range letDeclaration) context =
    case letDeclaration of
        Expression.LetFunction { declaration } ->
            rememberLetFunctionImplementation declaration context

        Expression.LetDestructuring pattern _ ->
            rememberPattern pattern context


rememberLetFunctionImplementation : Node Expression.FunctionImplementation -> Context -> Context
rememberLetFunctionImplementation (Node _ { arguments, name }) context =
    context
        |> rememberValue (Node.value name)
        |> rememberPatternList arguments


rememberPatternList : List (Node Pattern) -> Context -> Context
rememberPatternList list context =
    List.foldl rememberPattern context list


rememberPattern : Node Pattern -> Context -> Context
rememberPattern (Node _ pattern) context =
    case pattern of
        Pattern.VarPattern value ->
            rememberValue value context

        Pattern.TuplePattern values ->
            rememberPatternList values context

        _ ->
            context



--- ON EXIT


errorsForCaseList : List Expression.Case -> Context -> ( List (Rule.Error {}), Context )
errorsForCaseList list context =
    case list of
        [] ->
            ( [], context )

        first :: rest ->
            let
                ( firstErrors, firstContext ) =
                    errorsForCase first context

                ( restErrors, restContext ) =
                    errorsForCaseList rest firstContext
            in
            ( firstErrors ++ restErrors, restContext )


errorsForCase : Expression.Case -> Context -> ( List (Rule.Error {}), Context )
errorsForCase ( pattern, _ ) context =
    errorsForPattern pattern context


errorsForFunctionImplementation : Node Expression.FunctionImplementation -> Context -> ( List (Rule.Error {}), Context )
errorsForFunctionImplementation (Node _ { arguments }) context =
    errorsForPatternList arguments context


errorsForLetDeclarationList : List (Node Expression.LetDeclaration) -> Context -> ( List (Rule.Error {}), Context )
errorsForLetDeclarationList list context =
    case list of
        [] ->
            ( [], context )

        first :: rest ->
            let
                ( firstErrors, firstContext ) =
                    errorsForLetDeclaration first context

                ( restErrors, restContext ) =
                    errorsForLetDeclarationList rest firstContext
            in
            ( firstErrors ++ restErrors, restContext )


errorsForLetDeclaration : Node Expression.LetDeclaration -> Context -> ( List (Rule.Error {}), Context )
errorsForLetDeclaration (Node _ letDeclaration) context =
    case letDeclaration of
        Expression.LetFunction { declaration } ->
            errorsForLetFunctionImplementation declaration context

        Expression.LetDestructuring pattern _ ->
            errorsForPattern pattern context


errorsForLetFunctionImplementation : Node Expression.FunctionImplementation -> Context -> ( List (Rule.Error {}), Context )
errorsForLetFunctionImplementation (Node _ { arguments, name }) context =
    let
        ( nameErrors, nameContext ) =
            errorsForNode name context

        ( argsErrors, argsContext ) =
            errorsForPatternList arguments nameContext
    in
    ( nameErrors ++ argsErrors, argsContext )


errorsForPatternList : List (Node Pattern) -> Context -> ( List (Rule.Error {}), Context )
errorsForPatternList list context =
    case list of
        [] ->
            ( [], context )

        first :: rest ->
            let
                ( firstErrors, firstContext ) =
                    errorsForPattern first context

                ( restErrors, restContext ) =
                    errorsForPatternList rest firstContext
            in
            ( firstErrors ++ restErrors, restContext )


errorsForPattern : Node Pattern -> Context -> ( List (Rule.Error {}), Context )
errorsForPattern (Node range pattern) context =
    case pattern of
        Pattern.VarPattern value ->
            errorsForValue value range context

        Pattern.TuplePattern values ->
            errorsForPatternList values context

        _ ->
            ( [], context )



--- CONTEXT


type alias Context =
    Set String


initialContext : Context
initialContext =
    Set.empty


errorsForNode : Node String -> Context -> ( List (Rule.Error {}), Context )
errorsForNode (Node range value) context =
    errorsForValue value range context


errorsForValue : String -> Range -> Context -> ( List (Rule.Error {}), Context )
errorsForValue value range context =
    if Set.member value context then
        ( [ Rule.errorWithFix
                { message = "Pattern `" ++ value ++ "` is not used"
                , details =
                    [ "You should either use this value somewhere, or remove it at the location I pointed at."
                    ]
                }
                range
                [ Fix.replaceRangeBy range "_" ]
          ]
        , Set.remove value context
        )

    else
        ( [], context )


rememberValue : String -> Context -> Context
rememberValue value context =
    Set.insert value context


useValue : String -> Context -> Context
useValue value context =
    Set.remove value context
