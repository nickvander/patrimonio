//! Last-resort conversion of handler panics into honest 500s.
//!
//! A panic inside a handler used to unwind through hyper and drop the
//! connection: the client got no status code at all, just a severed request.
//! `GET /api/tax/summary?year=300000` did exactly that (the
//! `from_ymd_opt(...).unwrap()` family — now validated at the edge in
//! `api::tax`), and it was reachable by any authenticated user.
//!
//! The input validation is the real fix; this is the backstop, because the
//! codebase still has ~40 other `.unwrap()`s on parsed input and "no response
//! at all" is the worst possible failure mode — it looks like a network
//! fault, so it gets debugged as one. A 500 is at least honest, logged, and
//! leaves the connection usable.
//!
//! Lives here (not inline in `main.rs`) so the behavior is unit-testable:
//! the integration-test routers don't mount `main.rs`'s layer stack.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use tower_http::catch_panic::CatchPanicLayer;

type PanicPayload = Box<dyn std::any::Any + Send + 'static>;

fn panic_response(err: PanicPayload) -> Response {
    let detail = err
        .downcast_ref::<String>()
        .map(String::as_str)
        .or_else(|| err.downcast_ref::<&str>().copied())
        .unwrap_or("<non-string panic payload>");
    tracing::error!("Handler panicked: {detail}");
    // Generic body — the panic message can carry internals, and §1 says
    // never leak those on a 500.
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        axum::Json(serde_json::json!({ "error": "Internal server error" })),
    )
        .into_response()
}

/// The layer `main.rs` mounts OUTERMOST, so it wraps every other layer and
/// every handler.
pub fn layer() -> CatchPanicLayer<fn(PanicPayload) -> Response> {
    CatchPanicLayer::custom(panic_response as fn(PanicPayload) -> Response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use axum::routing::get;
    use axum::Router;
    use tower::ServiceExt;

    async fn boom() -> &'static str {
        panic!("secret internals: connection string, stack addresses")
    }

    #[tokio::test]
    async fn a_handler_panic_becomes_a_generic_500() {
        // Silence the expected panic's default stderr backtrace so the test
        // output stays readable; the hook is process-global, so scope it.
        let prev_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));

        let app = Router::new().route("/boom", get(boom)).layer(layer());
        let res = app
            .oneshot(Request::builder().uri("/boom").body(Body::empty()).unwrap())
            .await
            .expect("a response, not a severed connection");

        std::panic::set_hook(prev_hook);

        assert_eq!(res.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let bytes = axum::body::to_bytes(res.into_body(), 4096).await.unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            body,
            serde_json::json!({ "error": "Internal server error" }),
            "the panic payload must not leak to the client"
        );
    }
}
